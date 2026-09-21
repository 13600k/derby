# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Derby is a macOS AI model routing gateway. It exposes one OpenAI-compatible endpoint on
localhost and routes each request across many providers (metered APIs, subscription-backed
accounts, local model servers, custom OpenAI-compatible endpoints) according to a routing
policy that belongs to the *logical model* the client asked for.

The single most important idea: `model` in an inbound request is normally not a provider
model. It is a **logical model group** (`smart`, `coding`, `fast`, …) that resolves to a
ranked list of **provider targets**.

## Build / run / test

Pure SwiftPM, **no third-party dependencies**. Only the Command Line Tools are required
(there is no `.xcodeproj`; `xcodebuild` is not used).

```bash
swift build                        # debug build of DerbyCore + DerbyApp
swift build -c release             # release build
swift run DerbyTests               # all 453 tests (~5s, no network)
swift run DerbyTests Routing       # filter by suite or test name
DERBY_LIVE=1 swift run DerbyTests Live   # opt-in: this machine's real providers

./Scripts/build_app.sh             # assemble + ad-hoc sign build/Derby.app
./Scripts/build_app.sh --run       # ...and launch it
```

Two things follow from Command Line Tools being the only requirement:

1. The app bundle is assembled by hand in `Scripts/build_app.sh` (Info.plist + binary +
   generated icon + `codesign -s -`), because `xcodebuild` cannot build an Xcode project
   without full Xcode.
2. **`swift test` does not work** — Command Line Tools ship neither XCTest nor
   swift-testing, so a SwiftPM `testTarget` will not build. The suite is an
   `executableTarget` (`Tests/DerbyTests`) with a small harness in `Harness.swift`. Add new
   suites to `registerAllTests()` in `AllTests.swift` or they will not run.

## Architecture

Request flow, one direction only:

```
HTTP (Network.framework listener)
  → API/            translate the client dialect into CanonicalRequest
  → Registry/       resolve logical model → candidate ProviderTargets
  → Routing/        capability + health + budget filters, then a strategy ranks
                    survivors into a RoutePlan (with per-attempt timeouts)
  → Execution/      run the plan: retry, failover, hedging, deadline, cancellation
  → Handoff/        repair the conversation and shape it for the model each attempt reaches
  → Providers/      one adapter per protocol family speaks the wire format
  → Telemetry/      record attempts, usage, cost, routing explanation
```

Layer boundaries that must not be crossed:

- **Nothing outside `Providers/` may branch on which provider it is.** No
  `if kind == .anthropic` in routing, execution, API, or UI code. Provider differences are
  expressed as adapter behaviour or as declarative metadata (`ProviderKind` computed
  properties, `ModelCapabilities`).
- **Routing decides *where*, execution decides *how*, adapters speak protocol.** The router
  never performs I/O; it is a pure function of (request, snapshot, config) → `RoutePlan`,
  which is what makes the routing simulator and the routing tests possible.
- **Routing policies are data, not code paths.** A strategy is a `RoutingStrategy`
  implementation selected by a serialized `RoutingPolicy` value. Adding a strategy means
  adding one type and one enum case; it must not require touching the executor.
- **Retry ≠ failover.** Retry re-attempts the *same* target; failover advances to the *next*
  target. They have separate budgets and separate config.

### Control plane vs data plane

`ControlPlane/` owns mutable configuration and persists it to JSON (versioned, with
migrations in `ConfigMigrator`). The hot request path never reads that file: it consumes an
immutable `RoutingSnapshot` that is rebuilt whenever config changes and handed to requests
by reference. Secrets never enter the config file — the config stores a `SecretRef` and the
value lives in the Keychain (`Secrets/`).

### Failure handling

Every provider error is classified by its adapter into a `FailureKind` (the taxonomy in
`Canonical/CanonicalError.swift`). Routing behaviour is then driven by a
`FailureKind → FailureDisposition` table that is configurable per logical model. Add new
error handling by changing the classification or the table, not by adding branches in the
executor.

### What the client sees

`model` on the way in is an alias; `model` on the way out is the physical model that ran.
`RuntimeModelInfo` (built from the `ResolvedTarget`, so overrides and discovery are already
folded in) describes that model — context window, capabilities, pricing, provider kind — and
is surfaced as `x_derby.model`, as `x-derby-*` response headers, on the first SSE chunk of a
stream, and as `derby.active_model` in `GET /v1/models`. The listing calls the same `Router`
the request path does, so it never advertises something the next request will not use.
Streaming headers are `x-derby-planned-*`, since they are flushed before a target has run.
Physical model ids stay unroutable and are never listed as models — clients read the model,
they do not pick it, or routing and failover would be bypassed (`docs/CLIENTS.md`).

Inbound auth is **off by default**: a client needs the port and nothing else. What keeps
Derby off the network is the loopback `bindAddress`, not a key, and a gateway anything
running as this user can already reach gains nothing from one — while every client pays for
it in setup. `requireAPIKey` survives as the opt-in for a non-loopback bind (the 1 → 2
config migration leaves those alone). While it is off, an `Authorization` header is ignored
rather than rejected, because most OpenAI SDKs refuse to start without some key; while it is
on, a key that cannot be read from the Keychain **fails closed**. The default configuration
never touches the Keychain for the gateway key at all.

A **maximum output is serving policy, not a property of the weights** — the live index
carries caps from 16k to 262k for one copy of `qwen3.8-27b` — so it is only believed when it
came from the provider the account actually is. `RemoteModelCatalog.Entry.matchedOwnProvider`
is false when a row was found only by the cross-provider fallback, and a local server is
never its own publisher, so for one of those the limit stays unknown. That costs nothing (an
unknown limit never excludes a target) and is corrected by one field in the UI. Inheriting a
stranger's turned a vLLM box that imposes no cap at all into a 16k model, because a single
aggregator's row happened to answer first — and *which* row answered was not even stable,
since the fallback table was built by iterating an unordered dictionary.

What the server itself states always wins: llama.cpp's `/props` publishes
`default_generation_settings.params.n_predict` — `--n-predict` if one was set, `-1` for the
default of no ceiling — and that is read during discovery. Unlimited is recorded as
*unknown* rather than as a number, since the two behave identically in routing and inventing
one would make `/v1/models` promise an output floor no prompt can leave room for. vLLM
publishes nothing comparable, because it has no output cap: generation is bounded by
`max_model_len` minus the prompt, which the context filter already enforces.

Capability metadata is *completed*, not chosen: a provider's model list reports features but
seldom a context window, so `ModelCapabilities.completed(by:)` fills the gaps discovery left
from the bundled catalog. Only a model with `source == .unknown` takes the catalog wholesale.
Getting this wrong left every discovered model (the whole ChatGPT-subscription catalog) with
no context window, which silently disabled `minContextTokens` filtering and
`failoverToLargerContext`.

### Benchmark specs

`qualityScore` is the one number Derby cannot learn from anywhere: weighted-score routing
ranks by it, and nothing in a provider's model listing says how good a model is, so it was a
figure the user had to invent per model. `BenchmarkCatalog` fills it from Artificial
Analysis (`/api/v2/language/models`, `x-api-key`), cached on disk beside the models.dev
index and refreshed at most daily — the free tier allows 1,000 requests a day, so one press
of a button fetches the whole index, not one model.

Three rules keep it honest:

- **Nothing is on the request path.** A fetch copies what it takes into the model's *own*
  fields — `qualityScore`, `pricingOverride`, `capabilityOverrides.contextWindow` — which
  routing then reads exactly as it reads anything typed by hand. The full record stays on
  `PhysicalModel.benchmark` for display and provenance, and the router never reads it.
  `BenchmarkApplication.apply` is pure, so what a button press will write is testable.
- **A benchmark never contradicts the provider.** It fills a context window nobody reported
  and leaves a stated one alone; it skips pricing on local and subscription targets, whose
  marginal cost is zero whatever the hosted copy of the same weights is billed at.
- **Matching is exact or absent.** The index spells models its own way (`claude-4-5-sonnet`
  against Anthropic's `claude-sonnet-4-5`), so ids are normalized, date-stamped and
  namespaced forms are stripped, and token order is ignored — but a near-miss matches
  nothing, because a wrong match writes another model's score into a target the router
  ranks by. The matched row's name is recorded and shown, so a wrong one is findable.
- **An unspecified reasoning level means the highest.** The index publishes a row per
  effort; a provider publishes one endpoint that serves any of them, so rows differing only
  by level are one group and an id naming no level takes the group's ceiling. An id that
  *does* name one gets exactly that, falling to the strongest level below it when the index
  does not publish it. Ordering is by level, never by score — Qwen3.5 122B scores *higher*
  without reasoning, and taking the better number would undo the rule.
- **The level is stated in the row's name, not its slug.** `qwen3-5-9b` is "(Reasoning)"
  while `qwen3-5-9b-non-reasoning` is not — the bare slug is usually the reasoning row —
  and `gemini-3-5-flash` carries "(high)" in no slug at all. So the level is parsed from the
  name's trailing parenthetical and a row stating none is stripped of nothing, which is what
  keeps `mistral-medium-3-1` as Mistral Medium rather than a medium-effort anything. `max`
  counts as a level in a name ("Max Effort") but never in a slug or a provider's id, where
  Qwen Max and Grok 4 Max are weights.
- **A logical model's quality pin must not shadow a fetch.** `TargetRef.qualityOverride`
  wins over `PhysicalModel.qualityScore` everywhere routing reads it, and the quality field
  in the logical model view writes one on *any* commit — so tabbing through it froze the
  target at that moment and made every later fetch appear to do nothing. The field now only
  pins a value that differs from the model's own, and a fetch clears a pin that merely
  mirrored the old score while keeping (and reporting) one that says something different.
- **The endpoint pages.** It answers 200 rows and a `total_pages`; fetching only the first
  hid three quarters of the index, and with it every reasoning level that had not landed on
  page 1. `refresh` walks the pages and caches them as one document, stopping early if a
  page repeats what is already held (a server ignoring `page`) so a per-request quota is not
  spent re-reading it.

### Context compaction

Routing normally handles context by *selection*: a target whose window cannot hold
`prompt + reserved answer` is excluded, and if none fits the request fails with
`CONTEXT_OVERFLOW` (kept distinct from `CAPABILITY_MISMATCH`, because the remedy differs).
Derby does not shorten the conversation.

A logical model may opt out of that edge with a `CompactionPolicy` — off by default. It makes
a merely-too-small target eligible again (a target missing a *capability* is still excluded)
and `ContextCompactor` shortens the request per attempt, just before dispatch. Two rules are
load-bearing: **the cut always lands on a `user` message**, so an assistant's `tool_calls`
can never be orphaned from their `tool` results — providers reject that shape outright — and
**a final user message that cannot fit is an error, not something to truncate**. Compaction
is never silent: `x_derby.compaction`, the `x-derby-compacted` header, the routing
explanation and request history all carry it.

### Timeouts

Timeouts come from two scopes that mean different things, and are combined in exactly one
place — `ResolvedTimeouts.resolve`, which the router calls per attempt. A logical model's
`TimeoutConfig` is the **caller's patience**; a provider account's `AccountTimeouts` is the
**endpoint's requirement**. They are not two ceilings on one quantity, so they are not
`min`'d: an attempt gets the **longer** of the two. A `min` meant a provider setting could
only ever make Derby stricter — an account raised to 600s changed nothing while its logical
model still said 120s — and there was no account-level first-token setting at all, so a local
server prefilling a long tool loop was declared stalled at the logical model's figure however
the provider was configured.

- **A provider that says nothing loosens nothing.** `ProviderAccount`'s timeouts are optional;
  unset means the logical model decides alone and can be the stricter of the pair, which is
  what keeps a `fast`-style policy able to fail over quickly.
- **`overallSeconds` is the one ceiling nothing can raise.** Only the logical model sets it,
  the resolver clamps to it and the executor clips every wait by what is left of it.
- **A kind declares its own timing once**, in `ProviderKind.defaultTimeouts`, and
  `ProviderFactory` seeds new accounts from it — so a provider kind added later is right from
  creation with no `if kind == …` in routing, execution or the UI. Metered APIs declare
  nothing; local servers and CLI-backed accounts, which prefill or spawn before they speak,
  declare that they need minutes.
- **The first-token wait is per attempt, not per plan** (`PlannedAttempt.firstTokenTimeout`),
  because how long a server takes to say anything is a property of that server.

### Streaming

Failover is only transparent *before* the first byte reaches the client. Once content has
been streamed, the executor must not silently switch providers — see `StreamingSemantics`.
Adapters translate their native SSE dialect into `CanonicalStreamEvent`; the API layer
translates that back into the dialect the client asked in.

### Conversation hand-off

A conversation changes models routinely — between turns under a spreading strategy, within
one on failover. `Handoff/` exists so the answer differs because the model does, never
because something was lost in translation (`docs/ARCHITECTURE.md` has the full design). The
load-bearing rules:

- **Reasoning goes only to the same lineage** — `LineageAffinity.sharesReasoningFormat`
  (identical or same family), in a field the server reads, for the turns the receiving
  template reads back. Never across families.
- **Signed reasoning** (`ReasoningArtifact`: Anthropic signatures, OpenAI encrypted content,
  Gemini thought signatures) returns only to a model that can verify it, and only within the
  active tool loop — unless its protocol takes its own back from every turn
  (`AdapterFamily.replaysReasoningFromEarlierTurns`: the Responses API, whose stateless clients
  send every earlier reasoning item). Fable 5.1 binds thinking to the prefix it was issued with
  (enforced for newer accounts), so a block replayed out of context can fail the whole request.
- **Template behaviour is data.** It lives in `LineageTraits`; provider facts stay in
  `ProviderKind`/`AdapterFamily` properties. Nothing in `Handoff/` branches on a provider.
- **The ledger is a cache.** `HandoffLedger` is bounded; a miss may cost restored reasoning, never
  correctness. Its age limit counts from an entry's last use, so a conversation still going keeps
  its reasoning. `SQLiteHandoffLedgerStore` keeps what replay needs — opaque artifacts,
  attribution, the conversation an answer belongs to — in `derby.sqlite3` across restarts;
  plain-text reasoning is never written to disk.
- **A conversation stays one conversation on the provider's side.** It keeps the id of the
  conversation its recorded answers belong to (`CanonicalRequest.conversationKey`), so a client
  rewriting how its history begins, as compression does, does not start a new session. Routing
  keeps it on the account holding its reasoning (`RoutingPolicy.keepConversationsOnAccount`),
  reordering only copies of one model and never keeping a target that cannot answer.
- **Never silent.** Anything withheld, rewritten or repaired is counted in `HandoffRecord` and
  surfaced as `x_derby.handoff`, the `x-derby-handoff` header, the routing explanation and
  request history.

### Load, loaded models and disconnects

- The router stays pure. Load reaches it through the snapshot (`accountLoad`, `loadVersion`,
  `residency`); the **gateway** claims the chosen target with
  `HealthRegistry.reserve(_:accountID:ifLoadVersion:)` and routes again when the counts moved.
  The executor converts the reservation at `acquire` and releases whatever is left on exit.
- Warm-copy preference reorders only copies with the same `ModelLineage.identity`. It must
  never promote a different model.
- **A server's own account of its load beats Derby's.** `ProviderAdapter.occupancy` reads what
  vLLM, SGLang and llama.cpp publish (an `OccupancyStyle` per kind, never a branch), and
  `loadUtilization` takes whichever is worse. A server reporting no free slot is skipped while
  another target can answer, and kept when it is the only one — queueing beats failing. It is a
  learned rate limit, so it rides on `respectQuotas`. How much waiting counts as full is
  the provider's `RateLimitConfig.maxQueuedRequests` (none by default) — the server's whole queue,
  independent of `maxConcurrentRequests`. Where a server reports slots but no queue,
  `RoutingSnapshot.effectiveOccupancy` counts Derby's own requests beyond those slots as waiting.
- `HTTPServer` watches the socket while a handler runs and cancels it on EOF. **Only one
  receive may be outstanding on an `NWConnection`**: the watch and request parsing share
  `pendingReceive`, and each watch is numbered so a stale one cannot act for a later request.

## Provider integration notes

Verified live on this machine while building:

- **Anthropic subscription (Claude Code OAuth)** works: read the OAuth access token from the
  `Claude Code-credentials` Keychain item (or `~/.claude/.credentials.json`), call
  `POST https://api.anthropic.com/v1/messages` with `authorization: Bearer <token>` plus
  `anthropic-beta: oauth-2025-04-20`. The first system block **must** identify the caller as
  Claude Code or the token is rejected; the adapter injects it.
- **ChatGPT subscription (Codex OAuth)** uses `~/.codex/auth.json` →
  `POST https://chatgpt.com/backend-api/codex/responses` with `chatgpt-account-id`. Endpoint
  and headers confirmed; the local token was expired, so end-to-end success is unverified.
- **Ollama** verified live, streaming and non-streaming. Current builds honour
  `stream_options.include_usage`; older ones ignore it, which is why the executor estimates
  usage (flagged `isEstimated`) when a stream reports none.
- Derby reads CLI credential stores **read-only by default** ("linked" mode) so it can never
  invalidate the user's `claude`/`codex` login. Token refresh rotates the refresh token, so
  it is opt-in per account and writes the rotated tokens back to keep the CLI working.

Everything that speaks OpenAI's wire format (OpenRouter, Groq, Together, Fireworks, Mistral,
DeepSeek, xAI, Qwen/DashScope, Ollama, LM Studio, vLLM, llama.cpp, SGLang, LocalAI, plus any
user-supplied endpoint) is served by the single `OpenAIAdapter` configured with a different
base URL and quirk flags — do not add a new adapter for these.

## Conventions

- Swift 5 language mode on the Swift 6 compiler (`swiftLanguageMode(.v5)`); shared mutable
  state is guarded by actors, not locks.
- The suite must pass without network access: provider behaviour is tested through
  `MockTransport`/`MockAdapter`, never against real APIs. The HTTP and end-to-end suites do
  boot the real `Network.framework` listener on an ephemeral port.
- **Never race `Task.sleep` against a suspended `CheckedContinuation` in a task group.**
  Cancelling the child does not resume the continuation, so the group hangs at scope exit
  instead of abandoning the work. Resolve the *same* continuation from the timeout — see
  `AsyncEventChannel.next(timeout:)` and the watchdog in `HTTPServer.start`. This caused two
  real hangs during development.
- **Never name an app type after a SwiftUI type** (`Section`, `Group`, `List`, `Label`…).
  A sidebar enum called `Section` let `List(selection:)` resolve its selection type to
  `Section?` while rows were tagged `Section`; it compiled, and nothing in the sidebar was
  clickable. Single-selection `List` binds `Binding<SelectionValue?>` — the selection state
  must be **optional**.
- **Never add a non-optional stored property to a persisted `Codable` type.** Synthesized
  decoding then rejects every previously-saved document. Adding `unsupportedParameters` to
  `ModelCapabilities` made the whole `providers` array undecodable, and `DerbyConfig`'s
  tolerant `try?` turned that into five configured providers silently vanishing. Persisted
  types now decode field by field with `decodeIfPresent`, and `DerbyConfig.decodeFailures`
  reports any section that had to fall back so the loss is never silent again.
- A model's **capabilities** are what it can do; its **parameters** are what it will accept.
  They are independent — reasoning-era models are highly capable yet reject `temperature`,
  returning a deprecation error rather than ignoring it. `ModelCapabilities.unsupportedParameters`
  is a *deny-list*, so a model nothing is known about still receives everything.
- **A conversation must reach a provider as one conversation, byte for byte.** Prompt caches
  match exact prefixes, so encode what a provider renders with `JSONValue.stableJSONData()` — a
  Swift dictionary's key order changes between instances, and the same tool schemas came out
  reordered on nearly every turn — and name the conversation with
  `CanonicalRequest.conversationID(scope:)`, never a per-request id. With neither, a 55-step
  tool loop on ChatGPT had 0% of its input cached where the Codex CLI had 94%. The bytes rule is
  every adapter's, not ChatGPT's: a local server keys its cache on the prompt alone, and its chat
  template renders objects in the order their keys arrived. `OpenAIAdapter` kept a plain
  `JSONEncoder` after ChatGPT's was fixed, and Qwen on vLLM never read more than 1,600 tokens of a
  40K-token Hermes loop from its prefix cache. `AnthropicAdapter`, `GoogleAdapter` and
  `BedrockAdapter` still encode that way. `PromptCacheTests` checks a *growing* loop, not only a
  repeated request: each step must arrive as the step before plus what is new.
- **The look lives in `Views/Glass.swift`, and no other file branches on macOS
  version.** Derby's surfaces are tinted glass stained with `Color.derbyAccent`
  (teal, `#008080`). macOS 26 renders them as real Liquid Glass (`glassEffect`,
  `GlassEffectContainer`, `.buttonStyle(.glass)`); macOS 14/15 fall back to a
  blurred material under a tinted wash. Call sites say what a surface *is*
  (`.chrome`, `.panel`, `.chip`, `.raised`, `.inset`) and never which API drew it.
  The whole effect rests on one thing: `GlassWindowConfigurator` keeps the window
  non-opaque with a clear background. Restore an opaque fill anywhere — a
  `windowBackgroundColor` background, a solid `List` fill — and the glass has
  nothing to refract, so it collapses into flat coloured rectangles. Opacity is
  the *window's* job and transparency the *surfaces'*: the window carries a
  frosted backdrop under a pooled teal ground (`GlassTuning`), while the panes
  stay `Glass.clear` and refract it. Text never sits on bare glass — every
  surface lays `Color.derbyGlassScrim` between the glass and the content. The
  system appearance picks the text colour, so only an adaptive scrim can
  guarantee a background whose brightness matches it; without one, black text
  in light mode lands on whatever dark window happens to be behind Derby.
  On macOS 26 the glass is drawn as a *background layer* (`Color.clear.glassEffect`),
  never applied to the content itself: a `List` inside a view carrying
  `.glassEffect` never starts a drag, so `.onMove` silently stopped working in
  the logical models sidebar and the Targets card.
- Keychain reads can block on a system dialog. Keep them off the launch path and under a
  deadline; when a required key is unavailable the gateway must **fail closed**.

## Other agent configs present

A `~/.codex/config.toml` exists on this machine. If you want its MCP servers / prompts
available in Claude Code, reply `/import` to scan and list what is importable, then
`/import --yes=<digest>` with the digest that scan prints. (If `/import` is unavailable on
this surface, run `claude import` from a terminal.)
