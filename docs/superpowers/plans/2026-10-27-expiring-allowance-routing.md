# Expiring Allowance Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (native: you asked to
> optimize Claude Code usage). Implement the tasks in this session, in order. Steps use checkbox
> (`- [ ]`) syntax for tracking. When all tasks are done, use superpowers:requesting-code-review
> once for the whole branch.

**Goal:** Add a routing strategy `expiring_allowance`, plus a matching weighted-score dimension.
It sends each request to the plan account whose 5-hour allowance is most at risk of expiring
unused, then to other cloud targets, then to local models.

**Architecture:** `UsageMonitor`'s meter readings reach the pure router through
`RoutingSnapshot.planAllowances`, the same way local-server residency does. The router never
calls a meter. A new value type, `PlanAllowance`, turns a reading into an expiry score. A new
`RoutingStrategy` ranks targets by tier and score. `ScoreWeights` gains one dimension that reads
the same score. One declarative property on the strategy kind keeps a local target inside the
attempt cap.

**Tech Stack:** Swift 6 compiler in Swift 5 mode, SwiftPM, no dependencies. Tests use the custom
harness in `Tests/DerbyTests` (`swift run DerbyTests`).

**Spec:** The "Design" section below. These decisions were agreed in chat.

## Design

**Your decisions:**
- **Ranking uses time and unused allowance together.** A window resetting in 20 min at 95% used
  loses to one resetting in 2 h at 10% used.
- **Cloud targets with no plan window** come after plan accounts and before local.
- **Local is used when every cloud target is down.**

**Expiry score** = `unused / (unused + secondsLeft / duration)`, in 0…1.
- It sorts in the same order as `unused ÷ timeLeft`: the rate the leftover must be spent at to
  avoid losing it.
- Running window: `unused = 1 − usedFraction` and `secondsLeft = resetsAt − now`.
- Idle window (`PlanWarmUp.isIdle`), or a reset already in the past: `unused = 1` and
  `secondsLeft = duration`, so the score is 0.5. The sliding reset an idle meter reports is never
  read, so the ranking does not flap.
- **Spent** means an account-wide window (`scope == nil`) is exhausted with its reset still ahead;
  a weekly cap counts. `spentUntil` is the latest such reset, or `observedAt + duration` when the
  window gives none. Spent scores 0.
- The score uses only `PlanWarmUp.sessionWindow` (the shortest account-wide window under a day).
  Per-model caps (`scope != nil`) are ignored, because their scope strings can't be matched to
  target models.

**Tiers** (`ExpiringAllowanceStrategy`):

| Tier | Which targets | Order within the tier |
|---|---|---|
| 0 | Cloud with a plan window that is not spent | score, highest first; ties go to configured `order` |
| 1 | Cloud with no plan window (metered, counted, or never read) | configured order |
| 2 | Local | configured order |
| 3 | Spent cloud | `spentUntil` ascending, then configured order |

**Local slot:** when Router step 7 truncates to `limit = min(maxCandidates, maxAttempts)` and
that removes every local target, the last kept slot goes to the highest-ranked local target. This
only applies when `limit ≥ 2` and the strategy kind's `keepsLocalFallback` is true.

## Global Constraints

- No third-party dependencies. Only the Command Line Tools are needed. Tests run with
  `swift run DerbyTests` and must pass with no network.
- Every new suite is registered in `Tests/DerbyTests/AllTests.swift`.
- The router stays pure: no I/O and no actor calls. Plan data enters only through
  `RoutingSnapshot`.
- No `if kind == …` outside `Providers/`. Use `account.kind.isLocal` and
  `PlanWarmUp.sessionWindow`.
- New persisted `Codable` fields decode with `decodeIfPresent` and a default, never as required
  fields.
- Wire names are fixed: strategy raw value `"expiring_allowance"` and score key
  `"expiringAllowance"`.
- Shared mutable state lives in actors, and code follows the surrounding comment density and
  idiom.

## Review Focus

1. **No meter data at all** (fresh launch, monitor not polled, gateway tests): ranking falls back
   to cloud in configured order, then local, with no crash. Pinned in Task 3,
   `"no meter data falls back to configured order then local"`.
2. **A stale reading whose reset has passed** must score as a fresh window, never as spent or
   urgent. Pinned in Task 1, `"a past reset reads as a fresh window and is no longer spent"`.
3. **Weekly cap exhausted while the 5-hour window has room**: spent, ranked behind local. Pinned
   in Task 1 (`"an exhausted weekly window marks the plan spent"`) and Task 3 (`"tier order"`).
4. **More cloud targets than `maxAttempts`**: local must still be in the plan. Pinned in Task 4.
5. **A config saved before this feature** decodes with the new weight at 0. Pinned in Task 5.

---

### Task 0: Branch

- [ ] **Step 1:** Run `git checkout -b expiring-allowance-routing`. Copy this plan to
  `docs/superpowers/plans/2026-10-27-expiring-allowance-routing.md`.

### Task 1: `PlanAllowance`

**Files:**
- Create: `Sources/DerbyCore/Reliability/PlanAllowance.swift`
- Create: `Tests/DerbyTests/ExpiringAllowanceTests.swift`, defining
  `func registerExpiringAllowanceTests()`
- Modify: `Tests/DerbyTests/AllTests.swift`, to call `registerExpiringAllowanceTests()` after
  `registerPlanUsageTests()`

**Interfaces:**
- Consumes: `ProviderUsage`, `ProviderUsage.Window`, `PlanWarmUp.sessionWindow(_:)`,
  `PlanWarmUp.isIdle(_:observedAt:)` and `ProviderUsage.label(forWindowSeconds:)`.
- Produces:
  ```swift
  public struct PlanAllowance: Sendable, Hashable {
      public var duration: Double; public var usedFraction: Double
      public var resetsAt: Date?          // nil = idle
      public var spentUntil: Date?; public var observedAt: Date
      public init(duration: Double = ProviderUsage.fiveHours, usedFraction: Double,
                  resetsAt: Date?, spentUntil: Date? = nil, observedAt: Date = Date())
      public init?(usage: ProviderUsage)
      public func isSpent(now: Date) -> Bool
      public func secondsLeft(now: Date) -> Double
      public func unused(now: Date) -> Double
      public func expiryScore(now: Date) -> Double
      public func summary(now: Date) -> String
  }
  ```

- [ ] **Step 1: Write failing tests** in suite `"Expiring allowance / reading"`.

  Use `now = Date()` and `func window(_ used: Double, resetsIn: Double?, duration: Double = 18_000, scope: String? = nil)`
  as a local helper that builds a `ProviderUsage.Window`.

  - `"a running window scores by unused share over time left"`:
    - used 0.95, resets in 1200 → `expectClose(score, 0.4286)`.
    - used 0.10, resets in 7200 → `0.6923`.
    - used 0.50, resets in 1200 → `0.8824`.
    - `secondsLeft` ≈ 1200 (tolerance 2).
  - `"an idle window scores as a fresh one"`: three cases, each giving `expiryScore == 0.5` and
    `resetsAt == nil`:
    - used 0 with reset nil;
    - used 0 with a reset 18 000 s away;
    - used 0 with a reset 60 s in the past.
  - `"a past reset reads as a fresh window and is no longer spent"`: a memberwise allowance with
    `usedFraction 1`, `resetsAt = now − 60` and `spentUntil = now − 60` gives
    `isSpent(now) == false` and `expiryScore == 0.5`.
  - `"an exhausted weekly window marks the plan spent"`: a 5-hour window at 0.2 plus a weekly
    window (duration 604 800) at 1.0 resetting in 86 400 give `isSpent(now)` true, `spentUntil`
    ≈ now + 86 400, and `expiryScore == 0`.
  - `"a scoped window never marks the plan spent"`: an exhausted window with `scope: "opus"` gives
    `isSpent` false.
  - `"Derby's own count has no plan window"`: `ProviderUsage(source: .counted, …)` makes
    `PlanAllowance(usage:)` return nil.
  - `"summary names time and share left"`: used 0.38, resets in 6000 gives text that contains
    `"62% left"` and `"resets in"`. An idle allowance gives text that contains `"not started"`.

- [ ] **Step 2:** Run `swift run DerbyTests "Expiring allowance"`. Expected: build failure,
  because `PlanAllowance` is undefined.

- [ ] **Step 3: Implement `PlanAllowance`** following the Design.
  - Clamp `usedFraction` to 0…1, and treat nil as 0.
  - Take `spentUntil` from `usage.windows.filter { $0.scope == nil && $0.isExhausted }`.
  - Format time with compact h/m. Format the spent time with
    `formatted(date: .omitted, time: .shortened)`, which is what `UsageMonitor` uses.
  - The doc comment states this is the one piece of a plan meter the router reads.

- [ ] **Step 4:** Run `swift run DerbyTests "Expiring allowance"`. Expected: PASS.

- [ ] **Step 5:** Commit with the message "Read a plan window's expiring allowance".

### Task 2: Plan allowances reach the snapshot

**Files:**
- Modify: `Sources/DerbyCore/Reliability/UsageMonitor.swift`. Add the method, and change line 23,
  "the router never reads it", to say it reads `planAllowances()` through the snapshot.
- Modify: `Sources/DerbyCore/Reliability/ProviderUsage.swift:13` and `PlanWarmUp.swift:20`. Make
  the "router never reads" comments accurate.
- Modify: `Sources/DerbyCore/Routing/RoutingSnapshot.swift`
- Modify: `Sources/DerbyCore/Gateway/GatewayHandler.swift`. Add the init param, and set the field
  in `snapshot()`.
- Modify: `Sources/DerbyCore/Gateway/DerbyEngine.swift`. Set the field in `snapshot()`, and pass
  `usageMonitor` in `startGateway()`.
- Test: `Tests/DerbyTests/ExpiringAllowanceTests.swift`

**Interfaces:**
- Consumes: `PlanAllowance.init?(usage:)` from Task 1.
- Produces:
  - `UsageMonitor.planAllowances() -> [UUID: PlanAllowance]`, keyed by account id.
  - `RoutingSnapshot.planAllowances: [UUID: PlanAllowance] = [:]`.
  - `RoutingSnapshot.planAllowance(for: ResolvedTarget) -> PlanAllowance?`, which returns nil
    for a local target.
  - `GatewayHandler.init(…, usageMonitor: UsageMonitor? = nil)`.

- [ ] **Step 1: Write failing tests** in suite `"Expiring allowance / snapshot"`.
  - `"the monitor hands routing each plan's window"`. Accounts:
    - `plan` (`.chatgptSubscription`): fetch returns a 5-hour window, used 0.3, resetting in
      3600.
    - `metered` (`.openAICompatible`): fetch returns nil.
    - `local` (`.ollama`).

    After `await monitor.refresh()`, expect `Set(planAllowances().keys) == [plan.id]` and
    `usedFraction` close to 0.3.
  - `"a local target never carries a plan allowance"`: a snapshot whose `planAllowances` holds
    the local account's id still gives `planAllowance(for: localTarget) == nil`.

- [ ] **Step 2:** Run `swift run DerbyTests "Expiring allowance / snapshot"`. Expected: build
  failure.
- [ ] **Step 3: Implement.**
  - `planAllowances()` maps `statuses` through `$0.usage.flatMap(PlanAllowance.init(usage:))`.
  - Both snapshot builders set
    `snap.planAllowances = await usageMonitor.planAllowances()` next to `residency`. In
    `GatewayHandler` this is `?? [:]`.
- [ ] **Step 4:** Run the suite. Expected: PASS. Then run `swift build`, which must also compile
  `DerbyApp`.
- [ ] **Step 5:** Commit with the message "Carry plan allowances to the router through the
  snapshot".

### Task 3: `ExpiringAllowanceStrategy`

**Files:**
- Modify: `Sources/DerbyCore/ControlPlane/RoutingPolicy.swift`. Add the case, `displayName`,
  `summary` and `keepsLocalFallback`.
- Modify: `Sources/DerbyCore/Routing/Strategies.swift`. Add the `RoutingContext` fields, the
  strategy, and the registry case.
- Modify: `Sources/DerbyCore/Routing/Router.swift`, step 6.
- Modify: `docs/CLIENTS.md:179`. Say that `expiring_allowance`, like `weighted_random`, moves
  between targets over time.
- Test: `Tests/DerbyTests/ExpiringAllowanceTests.swift`

**Interfaces:**
- Consumes: Task 2's `snapshot.planAllowance(for:)`.
- Produces:
  - `RoutingStrategyKind.expiringAllowance` (`"expiring_allowance"`), with displayName
    "Expiring Allowance" and summary "Spend the plan allowance that would otherwise expire
    soonest, then other cloud targets, then local models."
  - `var keepsLocalFallback: Bool { self == .expiringAllowance }`.
  - `RoutingContext.planAllowances: [UUID: PlanAllowance]` (by target id) and `now: Date`, both
    defaulted in `init`.
  - `RoutingContext.planAllowance(for: ResolvedTarget) -> PlanAllowance?`.
  - `ExpiringAllowanceStrategy`, whose components key is `"expiringAllowance"`.

- [ ] **Step 1: Write failing tests** in suite `"Expiring allowance / strategy"`.

  Use a helper that routes with `.expiringAllowance` over a snapshot built with
  `planAllowances` set, returning `decision.plan.attempts.map(\.target.providerName)`. Set
  `maxCandidates` and `maxAttempts` to 8 so the cap stays out of the way.

  - `"most allowance at risk wins: 5% left in 20 min loses to 90% left in 2 h"`:
    `["B", "A"]` comes first.
  - `"half left in 20 min beats 90% left in 2 h"`: A first.
  - `"a running window beats an idle one with the same allowance"`: running at 0% with 16 200 s
    left beats idle.
  - `"tier order"`: accounts `Plan`, `Metered` (no allowance), `Local` (`.ollama`) and `Spent`
    (weekly exhausted), configured in the order Spent, Local, Metered, Plan, give
    `["Plan", "Metered", "Local", "Spent"]`.
  - `"no meter data falls back to configured order then local"`: Local, C1 and C2 with no
    allowances give `["C1", "C2", "Local"]`.
  - `"equal allowance keeps the configured order"`: one account with two models gives the models
    in configured order.
  - `"explanation and notes say why"`:
    - the top note contains `"left, resets in"`;
    - `decision.explanation` contains `"about to expire"`;
    - with only Local healthy (C1 has an open circuit via health), the explanation contains
      `"local fallback"`.

- [ ] **Step 2:** Run the suite. Expected: build failure, because the case does not exist.
- [ ] **Step 3: Implement.**
  - Router step 6: capture `let now = Date()` once in `route`, fill `planAllowances[t.id]`
    beside `warmth`, and pass `planAllowances` and `now` to `RoutingContext`.
  - Strategy: put each target in a tier and sort by `(tier, key, order)`.
    - Score: tier 0 uses `expiryScore`, every other tier uses 0.
    - Notes: tiers 0 and 3 use `summary(now:)`, tier 1 uses `"no plan meter"`, tier 2 uses
      `"local fallback"`.
  - `explain` gives one sentence per tier of the winner:
    - tier 0: "… has the most plan allowance about to expire (note)."
    - tier 1: "No plan window had allowance to spend, so … ranked first."
    - tier 2: "Every cloud target was unavailable, so … was used as the local fallback."
    - tier 3: "Only spent plans remained; … (note)."
- [ ] **Step 4:** Run the suite. Expected: PASS. Then run `swift run DerbyTests Strategies`.
  Expected: PASS.
- [ ] **Step 5:** Commit with the message "Add the expiring-allowance routing strategy".

### Task 4: Keep a local slot inside the attempt cap

**Files:**
- Modify: `Sources/DerbyCore/Routing/Router.swift`, step 7. Put the swap in a
  `static func keepingLocalFallback(_ ranked: [RankedTarget], limit: Int) -> (kept: [RankedTarget], displaced: RankedTarget?)`
  next to `preferWarmCopies`.
- Modify: `CLAUDE.md`, the "Plan usage" section. Replace "Display only: the router never reads
  it." with one bullet covering:
  - the snapshot path;
  - `unused ÷ timeLeft`;
  - idle counts as fresh;
  - spent goes behind local;
  - scoped caps are ignored;
  - the local slot.

  Also update the test count in "Build / run / test".
- Modify: `docs/ARCHITECTURE.md`. Add a short **Expiring allowance** paragraph after **Spare
  capacity**, under "Load, loaded models and disconnects".
- Test: `Tests/DerbyTests/ExpiringAllowanceTests.swift`

**Interfaces:**
- Consumes: `RoutingStrategyKind.keepsLocalFallback` from Task 3.

- [ ] **Step 1: Write failing tests** in suite `"Expiring allowance / local slot"`.

  Use 5 cloud accounts `C1`…`C5`, then `Local`, with `FailoverConfig(maxAttempts: 4)`.

  - `"the last slot goes to local when the cap would cut it"`:
    - the plan is `["C1", "C2", "C3", "Local"]`;
    - one `.cap` exclusion for C4 has a reason containing `"local fallback"`;
    - C5's reason contains `"beyond the 4-attempt limit"`.
  - `"other strategies keep the plain cap"`: `.cloudFirst` on the same config gives a plan
    without `"Local"`.
  - `"one attempt keeps the top target"`: with failover disabled, the plan is `["C1"]`.
- [ ] **Step 2:** Run the suite. Expected: FAIL. The first test's plan ends with `"C4"`.
- [ ] **Step 3: Implement.** Apply the swap only when `lm.policy.strategy.keepsLocalFallback`
  and `limit >= 2`. Record the displaced target as `.cap` with the reason
  `"gave its slot to the local fallback (<local label>)"`.
- [ ] **Step 4:** Run `swift run DerbyTests "Expiring allowance"` and
  `swift run DerbyTests Routing`. Expected: PASS.
- [ ] **Step 5:** Commit with the message "Keep a local fallback inside the attempt cap".

### Task 5: Score weight `expiringAllowance`

**Files:**
- Modify: `Sources/DerbyCore/ControlPlane/RoutingPolicy.swift`, `ScoreWeights`. Add a last
  `init` param `expiringAllowance: Double = 0`, plus `CodingKeys`, `decodeIfPresent ?? 0`,
  `dimensions` ("Expiring plan allowance", `\.expiringAllowance`), `total` and `normalized`.
- Modify: `Sources/DerbyCore/Routing/Scorer.swift`. Add `Dimensions.expiringAllowance`, include
  it in `weighted(by:)`, and add params `planAllowance: PlanAllowance? = nil, now: Date = Date()`
  to `dimensions(…)`. The value is `planAllowance?.expiryScore(now:) ?? 0`.
- Modify: `Sources/DerbyCore/Routing/Strategies.swift`. `WeightedScoreStrategy` passes
  `context.planAllowance(for: t)` and `context.now`. `label(for:)` maps `"expiringAllowance"` to
  "plan allowance about to expire".
- Test: `Tests/DerbyTests/ExpiringAllowanceTests.swift`

**Interfaces:**
- Consumes: Task 3's `RoutingContext.planAllowance(for:)` and `now`.

- [ ] **Step 1: Write failing tests** in suite `"Expiring allowance / score weight"`.
  - `"the weight alone prefers the allowance most at risk"`: use `.weightedScore` with every
    weight 0 except `expiringAllowance: 1`. A at 95% used with 1200 s left and B at 10% used with
    7200 s left put B first, and the top evaluation's `components` contains
    `"expiringAllowance"`.
  - `"weights saved before the dimension decode with it off"`: decoding `{"quality":0.35}` as
    `ScoreWeights` gives `expiringAllowance == 0`. Encoding and decoding
    `ScoreWeights(expiringAllowance: 0.4)` round-trips 0.4.
  - `"a target with no plan window scores zero on the dimension"`: `TargetScorer().dimensions`
    for a local target gives `expiringAllowance == 0`.
- [ ] **Step 2:** Run the suite. Expected: build failure, because there is no such argument.
- [ ] **Step 3: Implement** as listed under Files.
- [ ] **Step 4:** Run `swift run DerbyTests`. Expected: every test passes, and the count goes up
  by this branch's additions. Make sure the count in CLAUDE.md matches.
- [ ] **Step 5:** Commit with the message "Add expiring allowance as a score weight".

### Task 6: Verify in the app, then review

- [ ] **Step 1:** Quit the running Derby PID, then run
  `SDKROOT=…MacOSX26.5.sdk ./Scripts/build_app.sh --run`. This is a standing OK.
- [ ] **Step 2:** In the app, create a scratch logical model with both ChatGPT subscriptions and
  one local target, using **Expiring Allowance**. Press **Test Routing**, then check:
  - the winner has the highest share-left ÷ time-to-reset on the Overview meters;
  - the notes show "% left, resets in …";
  - local is last and still in the plan.

  Switch to Weighted Score with only "Expiring plan allowance" raised, and expect the same
  winner. Delete the scratch model afterwards. Your real logical models are not changed.
- [ ] **Step 3:** Run superpowers:requesting-code-review once over the whole branch. Report the
  results. No push or merge without your go-ahead.
