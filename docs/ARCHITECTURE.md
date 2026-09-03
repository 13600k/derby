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
   ↓  Routing/Router                 pure function, no I/O
   │    ├── availability filter      target/provider/model turned off
   │    ├── capability filter        vision, tools, json-schema, context window
   │    ├── health filter            open circuits, disabled targets
   │    ├── quota filter             provider-reported exhaustion
   │    ├── budget filter            per-request cost cap
   │    └── strategy.rank()          the logical model's own policy
RoutePlan  (ordered attempts + budgets)
   ↓  Execution/Executor             retry, failover, deadline, hedging, cancellation
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
  quota counters, in-flight counts, concurrency permits) mutates in one place.
- `TelemetryStore` is an actor wrapping SQLite; the executor hands records over and returns.
- `GatewayHandler` is a `Sendable` **struct**, deliberately not an actor — making it one
  would serialize every request behind a single executor.

### A concurrency bug worth remembering

Racing `Task.sleep` against a suspended `CheckedContinuation` inside a task group does *not*
abandon the operation: cancelling the child never resumes the continuation, so the group
waits forever at scope exit. This bit both the stream reader and the listener start-up.
The fix in both places is the same — **resolve the same continuation from the timeout**
rather than cancelling around it. See `AsyncEventChannel.next(timeout:)` and the watchdog in
`HTTPServer.start`.

## Streaming failover

`StreamingSemantics` states the rule in code:

- **Before** the first content-bearing token reaches the client, a failed attempt is
  invisible: Derby fails over and the client sees one clean stream.
- **After** content has been delivered, Derby never switches providers. The partial answer
  stands, the stream ends with an error event, and history records a mid-stream failure.

Splicing two models' output into one response would be worse than an honest error, so Derby
does not pretend a half-sent stream can be resumed.

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
├── Registry/       bundled model catalog (capabilities, context, list pricing)
├── Routing/        snapshot, router, scorer, strategies, route plan, explanations
├── Execution/      executor, deadlines, hedging, AsyncEventChannel
├── Providers/      adapter protocol, OpenAI, Anthropic, Google, Codex, Bedrock, SigV4
├── Reliability/    health registry, circuit breakers, rate limits, quotas
├── Telemetry/      request records, SQLite store, usage rollups, structured logs
├── HTTP/           NWListener server, SSE client, byte-level SSE parser
├── Storage/        paths, config store, migrations, export/import
├── Secrets/        Keychain store, redaction, CLI credential readers
└── Gateway/        engine, control-plane state, HTTP handler

Sources/DerbyApp/   SwiftUI app: one screen per concern, plus a menu bar extra
```
