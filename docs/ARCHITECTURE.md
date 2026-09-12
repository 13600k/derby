# Architecture

## Shape of the system

Derby is a single macOS app. The gateway runs **in-process** inside it — there is no helper
daemon, no XPC service and no IPC. That was a deliberate choice: a separate process would
add a supervision problem, a protocol, and two more failure modes, in exchange for surviving
a UI crash that a Swift app with no third-party code is unlikely to have. The cost is stated
plainly in [LIMITATIONS.md](LIMITATIONS.md).

```text
┌─────────────────────────────── Derby.app ───────────────────────────────┐
│                                                                          │
│  SwiftUI (DerbyApp)          ← reads snapshots, never the request path   │
│        │                                                                 │
│        ▼                                                                 │
│  DerbyEngine (actor)         ← lifecycle, config mutation, discovery     │
│        │                                                                 │
│  ┌─────┴──────────────┐                                                  │
│  │ ControlPlaneState  │      ← owns DerbyConfig, publishes RoutingSnapshot│
│  └─────┬──────────────┘                                                  │
│        │ immutable snapshot                                              │
│        ▼                                                                 │
│  HTTPServer → GatewayHandler → Router → Executor → ProviderAdapter → net │
│                     │                                    │               │
│                     └──────── HealthRegistry ────────────┘               │
│                                    │                                     │
│                              TelemetryStore (SQLite)                     │
└──────────────────────────────────────────────────────────────────────────┘
```

## The request path

```text
HTTP request
   ↓  API/OpenAIRequestParser        parse the client's dialect
CanonicalRequest                     provider-independent representation
   ↓  Handoff/HandoffLedger          restore what the client's dialect dropped
   ↓  Routing/Router                 pure function, no I/O
   │    ├── availability filter      target/provider/model turned off
   │    ├── capability filter        vision, tools, json-schema, context window
   │    ├── health filter            open circuits, disabled targets
   │    ├── quota filter             provider-reported exhaustion
   │    ├── budget filter            per-request cost cap
   │    └── strategy.rank()          the logical model's own policy
RoutePlan  (ordered attempts + budgets)
   ↓  Gateway/GatewayHandler         claim the first target when the ranking read live load
   ↓  Execution/Executor             retry, failover, deadline, hedging, cancellation
   ↓  Handoff/                       repair the conversation, then shape it for this attempt's model
   ↓  Providers/*Adapter             the only place a wire format is known
CanonicalResponse / CanonicalStreamEvent
   ↓  API/OpenAIResponseWriter       answer in the dialect that was asked
HTTP response
```

## The four abstractions

| Type | Answers | Never does |
| --- | --- | --- |
| `RoutePlan` | *Where* should this go, in what order, under what budget | Know a provider exists |
| `Executor` | *How and when* to attempt, retry, fail over, give up | Know a wire format |
| `ProviderAdapter` | *How to talk* to one protocol family | Make routing decisions |
| `RoutingSnapshot` | What the world looked like when this request started | Change mid-request |

## Rules that hold the design together

**1. Provider knowledge lives only in adapters.**
There is no `if kind == .anthropic` anywhere in routing, execution, the API layer or the UI.
Provider differences are either adapter behaviour or declarative data (`ProviderKind`
computed properties, `OpenAIQuirks`, `ModelCapabilities`). `AdapterRegistry` is the single
lookup table, and a test asserts every `ProviderKind` maps to the right family.

**2. The router is pure.**
`Router.route(_:snapshot:)` is synchronous and side-effect free: same inputs, same output.
That is what makes the routing simulator possible (it calls the *real* router, not a model
of it) and what lets 40-odd routing tests run in milliseconds with no mocking of time or
network.

**3. Policies are data.**
A strategy is a `RoutingStrategy` value selected by a serialized `RoutingStrategyKind`.
Adding one means adding a case and a type — `StrategyRegistry.strategy(for:)` is the only
place that changes. The executor is untouched.

**4. Retry and failover are separate concepts.**
`RetryConfig` governs re-attempts against the *same* target; `FailoverConfig` governs moving
to the *next* one. They have separate budgets, separate counters in request history, and
separate columns in the UI.

**5. Failure handling is a table, not a branch.**
Adapters classify errors into `FailureKind`. A `FailureKind → FailureDisposition` map —
defaulted per kind, overridable per logical model — decides what happens. Changing Derby's
behaviour for 429s is a config edit, not a code change.

## Control plane vs data plane

`ControlPlaneState` (an actor) owns the mutable `DerbyConfig` and derives a
`RoutingSnapshot` whenever it changes. The snapshot resolves every target once — provider,
model, capabilities, pricing, quality — so the hot path does no lookups and touches no disk.

A request captures the snapshot it started with. A configuration edit mid-flight produces a
new snapshot for *subsequent* requests and cannot disturb running ones. Live health is
merged in per request from `HealthRegistry` (one actor hop, a dictionary copy of a handful
of entries) so routing always sees current circuit and quota state.

## Concurrency

- `HTTPServer` gives every connection its own task, so a long stream never blocks others.
- `HealthRegistry` is one actor: all reliability state (rolling stats, circuit breakers,
  quota counters, in-flight counts, load reservations, concurrency permits) mutates in one
  place.
- `TelemetryStore` is an actor wrapping SQLite; the executor hands records over and returns.
- `GatewayHandler` is a `Sendable` **struct**, deliberately not an actor — making it one
  would serialize every request behind a single executor.
- `HandoffLedger` and `ResidencyRegistry` are actors too: the first remembers recent answers
  for the turn that follows them, the second what each local server last reported as loaded.

### A concurrency bug worth remembering

Racing `Task.sleep` against a suspended `CheckedContinuation` inside a task group does *not*
abandon the operation: cancelling the child never resumes the continuation, so the group
waits forever at scope exit. This bit both the stream reader and the listener start-up.
The fix in both places is the same — **resolve the same continuation from the timeout**
rather than cancelling around it. See `AsyncEventChannel.next(timeout:)` and the watchdog in
`HTTPServer.start`.

## What the client is told about the model

`model` in a request is an alias. `model` in the *response* never is: it is the physical
model that produced the answer. Around that, Derby reports what it knows about that model
at the moment it ran — context window, capabilities, pricing, provider kind, where the
metadata came from — as `RuntimeModelInfo`, built from the `ResolvedTarget` that served
the request, so it reflects overrides and discovery rather than the bundled catalog alone.

It reaches the client four ways:

| Surface | Carries |
| --- | --- |
| `x_derby.model` on every response | the model that answered, after any failover |
| `x-derby-*` response headers | model, provider, kind, context window, max output, capabilities (`x-derby-planned-*` on streams, which must send headers before a target runs) |
| the first SSE chunk (`x_derby`) | the same, *before* the first token, re-sent if a pre-content failover changes it |
| `GET /v1/models` | `derby.active_model` — what the alias resolves to right now — plus every target |

Physical model ids stay unroutable and unadvertised, so no client can pin a target and skip
routing; `docs/CLIENTS.md` is the client-side guide to reading the model instead of picking
it. `active_model` is computed by the same `Router` the request path uses, so the listing and
the next response agree. For strategies that deliberately spread traffic (weighted random,
round robin) the alias may resolve elsewhere on the next request; `x_derby.model` on the
response is always the authoritative answer, and `derby.targets` lists every possibility.

## Conversation state, context and model swapping

Derby is **stateless per request**, because the API it speaks is. A chat completion
carries its whole conversation in the `messages` array, so "a session" is just consecutive
requests from a client, each routed independently. Two consequences follow, and both are
deliberate:

**Derby never removes what was said unless told to.** By default it does not compact,
summarize, truncate or drop turns. What it does change is *form*, where the model receiving
the conversation would otherwise reject or misread it — see [Handing a conversation between
models](#handing-a-conversation-between-models). A router that silently dropped turns would
corrupt the conversation in a way the client could never detect.

**Context is handled by *selection*, not by trimming.** The capability filter excludes any
target whose window cannot hold `estimated prompt + reserved answer`, so a conversation that
has outgrown a small model simply stops being routed to it. If no target fits, the request
fails with `CONTEXT_OVERFLOW` rather than being quietly cut down — distinct from
`CAPABILITY_MISMATCH`, because the remedy is different: shorten the conversation, rather
than look for another model. When a provider disagrees with Derby's estimate and returns
`CONTEXT_OVERFLOW` itself, the disposition is `failoverToLargerContext`, which reorders the
remaining attempts to prefer a bigger window.

### Opting in to compaction

Selection alone has a hard edge: a 600k conversation cannot use a 262k local model even when
that is the only target left, so the request fails. A logical model can opt out of that edge
with a `CompactionPolicy`, which trades exactness for reach **explicitly**. It is off by
default and every affected response says so.

With it enabled, a target that is only *too small* stays eligible instead of being excluded
(a target missing a capability is still excluded — compaction can shrink a conversation, it
cannot give a model eyes). `ContextCompactor` then shortens the request just before dispatch,
per target, because each attempt has its own window:

- System and developer messages are pinned; they carry what makes the rest coherent.
- The most recent turns are kept verbatim.
- **The cut always lands on a `user` message.** A slice that begins on a `tool` result, or
  that keeps an assistant's `tool_calls` whose results were dropped, is rejected outright by
  every provider — that would turn a recoverable size problem into a hard 400.
- What was cut is either dropped (`drop_oldest`) or replaced by a summary from a model the
  user nominated (`summarize`). The transcript handed to that model is itself bounded by
  *its* window, so summarizing cannot overflow the summarizer.
- If summarizing fails, the turns are dropped instead and the failure is recorded. If even
  the final user message cannot fit, the request fails with `CONTEXT_OVERFLOW`: answering
  from a truncated question would produce a confidently wrong response.

None of this is silent. The result is reported as `x_derby.compaction`, on the
`x-derby-compacted` response header, in the routing explanation, and in request history.
Because it runs before the first byte is written, streaming needs no special case.

So when consecutive turns land on different models, the full conversation goes to whichever
one is chosen — one for one — and any model that could not hold it was never a candidate,
unless compaction was enabled, in which case it was shortened and the client was told.
The reserve matters here: with no `max_tokens` from the client, a request would otherwise
reserve nothing, and a 30k conversation could land on a 32k model with no room to reply.
`Router.defaultOutputReserveTokens` (or the logical model's default answer size) is added to
the requirement so a chosen target can actually answer.

What Derby does **not** do: session affinity. Nothing pins a conversation to the target that
served its previous turn, so a spreading strategy such as weighted random or round robin can
alternate models between turns. The weighted score's *conversation continuity* dimension can
favour the family that wrote the latest answer, but it is a weight, not a pin. For
deterministic behaviour within a conversation, use `priority` or `failover_chain`.

### Handing a conversation between models

When a turn — or a failover — lands on a different model from the one that wrote the
conversation so far, the next model reads a history written for another. What goes wrong
there usually has nothing to do with either model's ability: reasoning in a format the reader
was never trained on, a signed block it cannot verify, a tool call id it rejects, a system
prompt where its template never looks. The aim is an answer that differs because the model
differs, never because something was lost in translation.

How much can be carried depends on how closely the two are related. `ModelLineage` parses any
provider's model id into family, generation, tier, size and quantization, and grades a pair as
`identical` (the same weights, at any quantization, on any server), `same_family`,
`same_vendor`, `foreign` or `unknown`. What a family's chat template does with a history —
whether it writes `<think>` inline, which earlier turns it reads reasoning back for, whether it
demands alternating roles — is declared in `LineageTraits`, not branched on.

In request order:

1. **`HandoffLedger` restores what the client's dialect dropped.** A Chat Completions client
   sends history back without reasoning and without saying which model wrote each turn. Derby
   remembers its own answers — found again by tool call id, or by a fingerprint of the answer
   and the user message before it — and puts origin, reasoning and signed reasoning back on
   the matching turns before routing. It is in memory and bounded (4,096 answers, 24 MB,
   6 hours); losing it costs restored reasoning, never correctness.
2. **`ConversationNormalizer` repairs structure, whichever model is next.** Inline `<think>`
   text moves out of the answer; one turn sent as several Responses items becomes one turn;
   empty assistant turns go; every tool call is paired with a result — a result that lost its
   id is matched by position, one with no call becomes a user message, a call the conversation
   moved past is answered with an explicit "no result", and a result that arrives late is moved
   back behind its call.
3. **`HandoffPlanner` shapes the history for each attempt's target**, since a failover changes
   the reader:
   - *Reasoning text* reaches only an `identical` or `same_family` model, only in a field its
     server reads (`ProviderKind.reasoningReplayFields`), and only for the turns its template
     reads back (`LineageTraits.reasoningReplay`: Qwen's template reads reasoning for the open
     tool loop only; DeepSeek's thinking mode needs it on every turn once tools are involved).
   - *Signed reasoning* returns only to a model that can verify it — Anthropic thinking
     signatures to Claude, OpenAI encrypted reasoning to the account that issued it, Gemini
     thought signatures to Gemini — and only within the active tool loop, so any replayed
     prefix is one the provider issued. Gemini 3 requires a signature on each function call of
     the current turn; calls another model made carry Google's documented stand-in.
   - *Structure* follows the target: developer messages become system messages where the
     server knows only system; system messages move to the front, or into the first user
     message, where the template demands; consecutive user messages are joined for templates
     that require alternation; tool call ids are rewritten where the provider restricts them
     (Mistral's nine alphanumerics) — deterministically, so calls and results still match and
     the same history renders the same way every turn; images a tool returned move into a user
     message where tool results carry only text.
4. **Adapters capture and replay each provider's native artifacts** — thinking blocks with
   their signatures and redacted thinking, `encrypted_content` reasoning items,
   `thoughtSignature`, Bedrock's `reasoningContent` — as `ReasoningArtifact`s, so nothing above
   them knows a wire format.

On the way out, the executor splits inline `<think>` output into reasoning — on streams too,
holding back only what could be a partial tag — gives any tool call a provider left without an
id a unique one, and records the answer in the ledger.

None of it is silent. When the model changed, or anything was withheld or rewritten, a
`HandoffRecord` — previous model, affinity, reasoning carried and withheld, ids rewritten,
repairs — is reported as `x_derby.handoff`, in the routing explanation and in request history.
`HandoffPolicy.replayReasoning` turns reasoning replay off for a logical model entirely.

## Facts versus policy

A model's capabilities are **facts reported by its provider**, not preferences. They are
discovered, merged with bundled metadata to fill gaps, and shown read-only in Providers.
There is nothing to decide there: a model either accepts images or it does not.

What *is* a decision is the **contract a logical model presents**, and that lives with the
logical model:

| Where | What you set | Why there |
| --- | --- | --- |
| **Providers** | Price per token, intelligence score | Neither is knowable from the API — pricing varies by tier and contract, and quality is a judgement |
| **Providers** (only when unreported) | Context window, max output | A bare endpoint reports nothing, so there must be some way to supply it |
| **Logical Models** | Which shared capabilities to offer, context and answer caps | Narrowing is policy: the same model can serve a permissive group and a restricted one |

`LogicalModelConstraints` can only ever **subtract**. Unchecking vision hides a capability the
targets have; checking one they lack would be a promise Derby cannot keep, so it is ignored.
Constraints are enforced in the router, not merely displayed — a request needing a withheld
capability is refused with a clear error rather than routed to a target that happens to
support it, because otherwise `/v1/models` would be telling clients something untrue.

## What a logical model advertises

`/v1/models` reports two capability sets per alias, because merging them would be unsafe for
a client deciding *how to use* the model:

- `capabilities` — supported by **every** eligible target. A request relying on these keeps
  full failover.
- `available_capabilities` — supported by **at least one** target. These requests still work,
  since capability filtering routes them to the targets that qualify, but with fewer
  alternatives behind them. The difference is reported as `partial_capabilities`.

This is what makes mixed groups sound. A vision-capable model and a text-only model belong in
one alias: the group *guarantees* text and *offers* vision. A model that emits images rather
than text does not belong there at all — it cannot answer a chat request — and is reported
under `incompatible_targets` instead of skewing the group's advertised shape.

Context is reported the same way: top-level `context_window` is the largest window reachable
through the alias (safe, because an oversized prompt is filtered rather than truncated, and
stable as health changes), while `derby.min_context_window` is the floor that still fits every
target.

## Streaming failover

`StreamingSemantics` states the rule in code:

- **Before** the first content-bearing token reaches the client, a failed attempt is
  invisible: Derby fails over and the client sees one clean stream.
- **After** content has been delivered, Derby never switches providers. The partial answer
  stands, the stream ends with an error event, and history records a mid-stream failure.

Splicing two models' output into one response would be worse than an honest error, so Derby
does not pretend a half-sent stream can be resumed.

## Load, loaded models and disconnects

Three kinds of runtime awareness, each kept outside the pure router.

**Spare capacity.** `least_loaded`, and the `load` score dimension, rank on each account's
committed work — requests in flight plus requests routed there but not yet started — over its
concurrency limit, so a local server allowed two requests and an API allowed forty compare by
how full they are. Read naively, a burst piles onto one target, because every request in it
reads the same idle counts. So when a plan's ranking read load, `GatewayHandler` claims the
first target with `HealthRegistry.reserve(_:accountID:ifLoadVersion:)`, which succeeds only if
no count has moved since the snapshot was read; otherwise it routes again on fresh counts
(three tries, then it claims regardless — a burst that keeps moving the counts is already
being spread). The executor turns the reservation into the in-flight request when it
dispatches, which leaves the load version alone, and gives it back if it never does; an
unreturned reservation expires after 15 seconds. The router never reserves anything itself,
which is what keeps it pure.

**What the server itself says.** Derby's own counts see only Derby's traffic. A serving engine
sees everyone's, and knows what actually runs out first: vLLM and SGLang publish requests
running and waiting plus KV cache use as Prometheus gauges, and llama.cpp's `/slots` reports how
many decoding slots are busy. `ProviderAdapter.occupancy` reads whichever of those a server
speaks — declared per kind as an `OccupancyStyle`, never branched on — and the poller keeps it
beside the loaded-model report. `loadUtilization` then takes whichever is worse, Derby's view or
the server's, so a box someone else is already hammering ranks as busy even when Derby has sent
it nothing.

A server reporting **no free slot** — every slot taken, work queued, or the KV cache effectively
full — is passed over while another target can answer now, and recorded as an exclusion carrying
what the server said. It is not an error: the request would only queue, so a full server stays
eligible when it is the only one left. There is no setting for it. This is a rate limit learned
from the server rather than configured, so it follows the logical model's existing
`respectQuotas` switch and adds no new knob.

**Loaded models.** While the gateway runs, `DerbyEngine` asks each enabled local server every
5 seconds what it holds in memory (`ProviderAdapter.loadedModels`) and keeps the answers in
`ResidencyRegistry`. A report older than 30 seconds is not trusted, and a target that answered
within the last four minutes counts as recently used. Among copies of the same model — the
same `ModelLineage.identity` — the router moves a loaded copy ahead of a cold one and leaves
every other position where the strategy put it. It is on by default except under `priority`
and `failover_chain`, where the user's order is the instruction. Warmth is also a score
dimension and `least_loaded`'s tie-break.

**Disconnects.** A client that gives up used to be noticed only at the next write — after a
non-streaming answer had been generated in full, or at a stream's next chunk — while a local
model kept generating for nobody. `HTTPServer` watches the socket while a handler or stream
producer runs and cancels its task on EOF; the cancellation reaches the provider request
through the executor. The watch and request parsing share one outstanding receive, so bytes a
pipelining client sends meanwhile are kept for the next request rather than raced for, and
each watch is numbered, so one left over from an earlier request on a keep-alive connection
can never cancel — or swallow the signal meant for — the current one.

## Persistence

- `config.json` — versioned, migrated on the raw JSON *before* decoding (so renames and
  restructures are possible), written atomically at `0600`, backed up on schema change, and
  moved aside rather than crashing the app if it is corrupt.
- `derby.sqlite3` — request history, attempts, usage rollups and logs, in WAL mode, pruned
  by retention rules.
- **Keychain** — every secret. The config file holds only a `SecretRef`.

## Module map

```text
Sources/DerbyCore/
├── Canonical/      CanonicalRequest/Response/StreamEvent/Error, capabilities
├── ControlPlane/   DerbyConfig, providers, logical models, policies, pricing, settings
├── Registry/       bundled model catalog, resolved runtime model metadata, model lineage
├── Routing/        snapshot, router, scorer, strategies, route plan, explanations
├── Handoff/        conversation normalizer, hand-off planner, answer ledger, think-tag splitting
├── Execution/      executor, deadlines, hedging, AsyncEventChannel
├── Providers/      adapter protocol, OpenAI, Anthropic, Google, Codex, Bedrock, SigV4
├── Reliability/    health registry, circuit breakers, rate limits, quotas, load reservations, loaded models
├── Telemetry/      request records, SQLite store, usage rollups, structured logs
├── HTTP/           NWListener server, SSE client, byte-level SSE parser
├── Storage/        paths, config store, migrations, export/import
├── Secrets/        Keychain store, redaction, CLI credential readers
└── Gateway/        engine, control-plane state, HTTP handler

Sources/DerbyApp/   SwiftUI app: one screen per concern, plus a menu bar extra
```
