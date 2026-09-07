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
swift run DerbyTests               # all 363 tests (~4s, no network)
swift run DerbyTests Routing       # filter by suite or test name

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

Capability metadata is *completed*, not chosen: a provider's model list reports features but
seldom a context window, so `ModelCapabilities.completed(by:)` fills the gaps discovery left
from the bundled catalog. Only a model with `source == .unknown` takes the catalog wholesale.
Getting this wrong left every discovered model (the whole ChatGPT-subscription catalog) with
no context window, which silently disabled `minContextTokens` filtering and
`failoverToLargerContext`.

### Context compaction

Routing normally handles context by *selection*: a target whose window cannot hold
`prompt + reserved answer` is excluded, and if none fits the request fails with
`CONTEXT_OVERFLOW` (kept distinct from `CAPABILITY_MISMATCH`, because the remedy differs).
Derby does not rewrite the conversation.

A logical model may opt out of that edge with a `CompactionPolicy` — off by default. It makes
a merely-too-small target eligible again (a target missing a *capability* is still excluded)
and `ContextCompactor` shortens the request per attempt, just before dispatch. Two rules are
load-bearing: **the cut always lands on a `user` message**, so an assistant's `tool_calls`
can never be orphaned from their `tool` results — providers reject that shape outright — and
**a final user message that cannot fit is an error, not something to truncate**. Compaction
is never silent: `x_derby.compaction`, the `x-derby-compacted` header, the routing
explanation and request history all carry it.

### Streaming

Failover is only transparent *before* the first byte reaches the client. Once content has
been streamed, the executor must not silently switch providers — see `StreamingSemantics`.
Adapters translate their native SSE dialect into `CanonicalStreamEvent`; the API layer
translates that back into the dialect the client asked in.

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
- Keychain reads can block on a system dialog. Keep them off the launch path and under a
  deadline; when a required key is unavailable the gateway must **fail closed**.

## Other agent configs present

A `~/.codex/config.toml` exists on this machine. If you want its MCP servers / prompts
available in Claude Code, reply `/import` to scan and list what is importable, then
`/import --yes=<digest>` with the digest that scan prints. (If `/import` is unavailable on
this surface, run `claude import` from a terminal.)
