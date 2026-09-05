# Development

## Requirements

macOS 14+, Swift 6 toolchain. **Command Line Tools are sufficient** — there is no
`.xcodeproj` and `xcodebuild` is never invoked. No third-party dependencies.

```bash
swift --version        # expects Apple Swift 6.x
```

## Everyday commands

```bash
swift build                        # DerbyCore + DerbyApp
swift build -c release
swift build --target DerbyCore     # library only, fastest loop

swift run DerbyTests               # whole suite (~4s, no network)
swift run DerbyTests Routing       # filter by suite or test name
swift run DerbyTests "circuit"

./Scripts/build_app.sh             # → build/Derby.app (release, ad-hoc signed)
./Scripts/build_app.sh --debug     # faster build
./Scripts/build_app.sh --run       # build and launch
./Scripts/build_app.sh --install   # also copy into /Applications
```

## Why the tests are an executable

Command Line Tools ship neither XCTest nor swift-testing, so a SwiftPM `testTarget` cannot
build without a full Xcode install. `Tests/DerbyTests` is therefore an ordinary
`executableTarget` with a small harness in `Harness.swift`:

```swift
suite("Routing / capability filtering") {
    test("targets missing a required capability are filtered out") {
        ...
        try expectEqual(decision.plan.attempts.count, 1)
    }
}
```

`registerAllTests()` in `AllTests.swift` lists every suite explicitly, so a new file is never
silently skipped. Exit status is non-zero on failure, which is all CI needs.

Assertions: `expect`, `expectEqual`, `expectClose`, `expectNotNil`, `expectNil`,
`expectContains`, `expectThrows`, and `expectFailure(_ kind:)` for Derby's error taxonomy.

## Test coverage

195 tests, no network access required. Provider behaviour is exercised through `MockTransport`
(scripted HTTP with real provider payloads) and `MockAdapter` (scripted successes, failures,
delays and hangs). The HTTP and end-to-end suites boot the **real** `Network.framework`
listener on an ephemeral port and drive it with `URLSession`.

| Suite | Covers |
| --- | --- |
| Canonical | request normalization (chat, Responses, embeddings), multimodal, tools, stream accumulation, cost |
| Capabilities | flags, requirements, overrides, catalog lookups and safe degradation |
| Routing | resolution, every filter stage, candidate caps, plan shape, explanations |
| Strategies | all nine strategies, weight normalization, distribution, per-model independence |
| Execution | retry vs failover, dispositions, deadlines, streaming semantics, hedging, concurrency, usage estimation |
| Reliability | rolling stats, circuit lifecycle, admission control, rate-limit header parsing |
| Providers | OpenAI/Anthropic/Google body shaping and parsing, error classification, Azure, SigV4, event-stream framing |
| HTTP | SSE parsing at byte granularity, real server: keep-alive, concurrency, chunked SSE, oversized bodies |
| Persistence | full config round-trip, corruption recovery, migration, export/import, Keychain, SQLite |
| End to end | HTTP → routing → mock provider → OpenAI response, streaming, failover, circuits, auth, restart |

## Adding things

### A new OpenAI-compatible service

Do **not** write an adapter. Add a `ProviderKind` case, its `displayName` and
`defaultBaseURL`, and a branch in `OpenAIQuirks.forKind` if it deviates from the spec:

```swift
case .myService:
    q.supportsStreamOptions = false      // server 400s on unknown fields
    q.supportsParallelToolCalls = false
```

### A provider with its own protocol

Implement `ProviderAdapter`, add an `AdapterFamily` case, map your `ProviderKind` to it in
`adapterFamily`, and register it in `AdapterRegistry.init`. Nothing else changes — the
`ProviderTests` registry test will hold you to the mapping.

The protocol has defaults for `listModels`, `capabilities`, `embed`, `healthCheck` and
`rateLimitSnapshot`, so a minimal adapter needs `authenticate`, `execute`, `stream` and
`classifyError`.

**Classify errors carefully.** `FailureKind` drives retry, failover and circuit breakers;
getting `rateLimit` vs `quotaExhausted` vs `authentication` wrong changes behaviour more
than any other single thing in an adapter.

### A new routing strategy

```swift
public struct MyStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .myStrategy
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] { ... }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String { ... }
}
```

Add the enum case (with `displayName` and `summary`, which the UI renders automatically) and
one line in `StrategyRegistry`. The executor and every adapter are untouched. `explain` is
not optional in spirit — it is what the user reads in request history.

### A config schema change

Bump `DerbyConfig.currentSchemaVersion` and add a block to `ConfigMigrator.migrate`, which
operates on the raw JSON object before decoding:

```swift
if version == 1 {
    rawObject["logicalModels"] = ...rewrite...
    version = 2
    notes.append("Migrated logical models to schema 2")
}
```

The previous document is backed up automatically when the version changes.

## Debugging

- **Logs** screen, or `~/Library/Application Support/Derby/derby.sqlite3`.
- **Requests** screen shows every attempt, score and exclusion for a request.
- **Routing** screen simulates a decision without spending tokens.
- `GET /v1/derby/status` dumps every target of every logical model: its runtime metadata
  (`id`, `provider`, `context_window`, `capabilities`, `pricing`, …) alongside `available`,
  `health`, `circuit` and `p50_ms`. Same per-target shape as `derby.targets` in
  `GET /v1/models`.
- `GET /metrics` is Prometheus text.
- Settings → *Export Diagnostics* writes a redacted dump.

Data lives in `~/Library/Application Support/Derby/`:
`config.json`, `derby.sqlite3`, `Backups/`.

## Conventions

- Swift 5 language mode on the Swift 6 compiler (`swiftLanguageMode(.v5)`).
- Shared mutable state is guarded by **actors**, not locks; locks only appear in leaf types
  that must be callable from non-async contexts.
- Secrets never reach a log: everything user-visible goes through `SecretRedactor`.
- Errors carry a `FailureKind` and a message a user can act on. "Something went wrong" is a
  bug.
