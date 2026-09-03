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
swift run DerbyTests               # all 195 tests (~4s, no network)
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
- Keychain reads can block on a system dialog. Keep them off the launch path and under a
  deadline; when a required key is unavailable the gateway must **fail closed**.

## Other agent configs present

A `~/.codex/config.toml` exists on this machine. If you want its MCP servers / prompts
available in Claude Code, reply `/import` to scan and list what is importable, then
`/import --yes=<digest>` with the digest that scan prints. (If `/import` is unavailable on
this surface, run `claude import` from a terminal.)
