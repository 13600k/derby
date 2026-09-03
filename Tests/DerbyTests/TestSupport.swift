import Foundation
@testable import DerbyCore

// MARK: - Programmable transport

/// Scripted HTTP transport. Adapters are exercised against realistic provider
/// payloads with no network involved.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: JSONValue?
    }

    private let lock = NSLock()
    private var _requests: [Recorded] = []
    var responses: [String: OutboundResponse] = [:]
    var streams: [String: [String]] = [:]
    var defaultResponse: OutboundResponse?
    var artificialDelay: Double = 0
    var failWith: DerbyError?

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func stub(_ pathSuffix: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        responses[pathSuffix] = OutboundResponse(status: status, headers: headers, body: Data(json.utf8))
    }
    func stubStream(_ pathSuffix: String, events: [String]) {
        streams[pathSuffix] = events
    }

    private func record(_ request: OutboundRequest) {
        lock.lock()
        _requests.append(Recorded(url: request.url, method: request.method, headers: request.headers,
                                  body: request.body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }))
        lock.unlock()
    }

    func send(_ request: OutboundRequest) async throws -> OutboundResponse {
        record(request)
        if artificialDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000)) }
        if let failWith { throw failWith }
        if let key = responses.keys.first(where: { request.url.path.hasSuffix($0) }) {
            return responses[key]!
        }
        if let d = defaultResponse { return d }
        throw DerbyError(kind: .providerDown, message: "No stub for \(request.url.path)")
    }

    func stream(_ request: OutboundRequest) async throws -> StreamStart {
        record(request)
        if let failWith { throw failWith }
        if let key = responses.keys.first(where: { request.url.path.hasSuffix($0) }),
           let stub = responses[key], !(200..<300).contains(stub.status) {
            return StreamStart(status: stub.status, headers: stub.headers,
                               events: AsyncThrowingStream { $0.finish() }, errorBody: stub.body)
        }
        guard let key = streams.keys.first(where: { request.url.path.hasSuffix($0) }),
              let events = streams[key] else {
            throw DerbyError(kind: .providerDown, message: "No stream stub for \(request.url.path)")
        }
        let delay = artificialDelay
        return StreamStart(status: 200, headers: [:], events: AsyncThrowingStream { c in
            Task {
                for e in events {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    c.yield(SSEEvent(data: e))
                }
                c.finish()
            }
        }, errorBody: nil)
    }

    var lastBody: JSONValue? { requests.last?.body }
    var requestCount: Int { requests.count }
    func reset() { lock.lock(); _requests.removeAll(); lock.unlock() }
}

// MARK: - Programmable adapter

/// A provider adapter whose behaviour is scripted per model, so routing,
/// retry, failover and circuit-breaker behaviour can be tested precisely.
final class MockAdapter: ProviderAdapter, @unchecked Sendable {
    let family: AdapterFamily = .openai

    enum Behaviour: Sendable {
        case succeed(text: String, delay: Double = 0,
                     usage: CanonicalUsage = CanonicalUsage(inputTokens: 10, outputTokens: 5))
        case fail(DerbyError)
        /// Fail the first `count` calls, then succeed.
        case failThenSucceed(count: Int, error: DerbyError, text: String)
        case hang(seconds: Double)
    }

    private let lock = NSLock()
    private var behaviours: [String: Behaviour] = [:]
    private var callCounts: [String: Int] = [:]
    private var _defaultBehaviour: Behaviour = .succeed(text: "ok")

    var defaultBehaviour: Behaviour {
        get { lock.lock(); defer { lock.unlock() }; return _defaultBehaviour }
        set { lock.lock(); _defaultBehaviour = newValue; lock.unlock() }
    }

    func set(_ model: String, _ behaviour: Behaviour) {
        lock.lock(); behaviours[model] = behaviour; lock.unlock()
    }
    func calls(_ model: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return callCounts[model] ?? 0
    }
    var totalCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return callCounts.values.reduce(0, +)
    }
    func resetCounts() { lock.lock(); callCounts.removeAll(); lock.unlock() }

    private func nextBehaviour(_ model: String) -> Behaviour {
        lock.lock(); defer { lock.unlock() }
        let n = callCounts[model] ?? 0
        callCounts[model] = n + 1
        let b = behaviours[model] ?? _defaultBehaviour
        if case .failThenSucceed(let count, let error, let text) = b {
            return n < count ? .fail(error) : .succeed(text: text)
        }
        return b
    }

    func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth { ResolvedAuth() }

    func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        ctx.account.models.map { DiscoveredModel(id: $0.modelID) }
    }

    func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        switch nextBehaviour(model) {
        case .succeed(let text, let delay, let usage):
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            return CanonicalResponse(id: IDGenerator.requestID(), model: model,
                                     message: .assistant(text), usage: usage)
        case .fail(let e):
            throw e
        case .hang(let s):
            try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            throw DerbyError(kind: .unknown, message: "hang should have been cancelled")
        case .failThenSucceed:
            throw DerbyError(kind: .unknown, message: "unreachable")
        }
    }

    func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let behaviour = nextBehaviour(model)
        // Errors that happen before the stream opens must surface here, so the
        // executor can fail over transparently.
        if case .fail(let e) = behaviour { throw e }
        return AsyncThrowingStream { c in
            Task {
                switch behaviour {
                case .succeed(let text, let delay, let usage):
                    c.yield(.start(id: IDGenerator.requestID(), model: model))
                    for word in text.split(separator: " ") {
                        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                        c.yield(.textDelta(String(word) + " "))
                    }
                    c.yield(.usage(usage))
                    c.yield(.finish(.stop))
                    c.finish()
                case .hang(let s):
                    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                    c.finish(throwing: DerbyError(kind: .unknown, message: "hang should have been cancelled"))
                case .fail(let e):
                    c.finish(throwing: e)
                case .failThenSucceed:
                    c.finish(throwing: DerbyError(kind: .unknown, message: "unreachable"))
                }
            }
        }
    }

    func embed(_ request: CanonicalEmbeddingRequest, model: String, ctx: ProviderContext) async throws
        -> CanonicalEmbeddingResponse {
        _ = nextBehaviour(model)
        return CanonicalEmbeddingResponse(model: model,
                                          vectors: request.inputs.map { _ in [0.1, 0.2, 0.3] },
                                          usage: CanonicalUsage(inputTokens: 4))
    }

    func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        DerbyError(kind: .transient, message: "mock", providerStatus: status)
    }
}

/// A mid-stream failure: yields some content, then fails. Used to prove Derby
/// does not splice two providers' output together.
final class MidStreamFailAdapter: ProviderAdapter, @unchecked Sendable {
    let family: AdapterFamily = .openai
    let failAfterTokens: Int
    init(failAfterTokens: Int = 2) { self.failAfterTokens = failAfterTokens }

    func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth { ResolvedAuth() }
    func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        throw DerbyError(kind: .transient, message: "mid-stream adapter is streaming-only")
    }
    func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let n = failAfterTokens
        return AsyncThrowingStream { c in
            Task {
                c.yield(.start(id: "x", model: model))
                for i in 0..<n { c.yield(.textDelta("tok\(i) ")) }
                c.finish(throwing: DerbyError(kind: .transient, message: "provider dropped the connection"))
            }
        }
    }
    func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        DerbyError(kind: .transient, message: "mock", providerStatus: status)
    }
}

// MARK: - Fixtures

enum Fixture {
    static func model(_ id: String, quality: Double = 70,
                      caps: CapabilityFlags = [.text, .streaming, .tools],
                      context: Int? = 128_000, pricing: Pricing? = nil) -> PhysicalModel {
        PhysicalModel(modelID: id, enabled: true,
                      capabilities: ModelCapabilities(flags: caps, contextWindow: context,
                                                      maxOutputTokens: 8192, source: .builtin),
                      pricingOverride: pricing,
                      qualityScore: quality)
    }

    static func account(_ name: String, kind: ProviderKind = .openAICompatible,
                        models: [PhysicalModel], preference: Double = 50,
                        maxConcurrent: Int = 8) -> ProviderAccount {
        ProviderAccount(name: name, kind: kind, enabled: true,
                        baseURLOverride: "http://127.0.0.1:9/v1",
                        auth: .none,
                        rateLimits: RateLimitConfig(maxConcurrentRequests: maxConcurrent),
                        models: models, preferenceScore: preference)
    }

    static func logical(_ name: String, accounts: [ProviderAccount],
                        strategy: RoutingStrategyKind = .priority,
                        weights: ScoreWeights = .balanced,
                        retry: RetryConfig = RetryConfig(maxRetriesPerTarget: 0, initialBackoffSeconds: 0.001),
                        failover: FailoverConfig = .default,
                        timeouts: TimeoutConfig = TimeoutConfig(overallSeconds: 10, perAttemptSeconds: 5,
                                                                firstTokenSeconds: 3),
                        required: CapabilityFlags = [],
                        targetWeights: [Double]? = nil,
                        hedging: HedgeConfig = .disabled) -> LogicalModel {
        var targets: [TargetRef] = []
        var i = 0
        for a in accounts {
            for m in a.models {
                targets.append(TargetRef(providerID: a.id, modelUUID: m.id,
                                         weight: targetWeights?[safe: i] ?? 1))
                i += 1
            }
        }
        return LogicalModel(name: name, enabled: true, targets: targets,
                            policy: RoutingPolicy(strategy: strategy, scoreWeights: weights, deterministic: true),
                            retry: retry, failover: failover, timeouts: timeouts, hedging: hedging,
                            requiredCapabilities: required)
    }

    static func config(accounts: [ProviderAccount], logicalModels: [LogicalModel]) -> DerbyConfig {
        DerbyConfig(gateway: GatewaySettings(port: 0, requireAPIKey: false, autoStart: false),
                    providers: accounts, logicalModels: logicalModels,
                    health: HealthSettings(windowSize: 20, failureThreshold: 2, minimumSamples: 2,
                                           openDurationSeconds: 60),
                    logging: LoggingSettings(level: .debug))
    }

    static func snapshot(_ config: DerbyConfig, health: [TargetKey: TargetHealth] = [:]) -> RoutingSnapshot {
        RoutingSnapshot.build(config: config, health: health, version: 1)
    }

    /// A ready-made executor wired to a mock adapter.
    static func executor(adapter: MockAdapter = MockAdapter(),
                         health: HealthRegistry,
                         sink: RecordingSink = RecordingSink()) -> Executor {
        Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                 transport: MockTransport(),
                 secrets: InMemorySecretStore(),
                 credentials: CredentialCache(),
                 health: health,
                 telemetry: sink)
    }

    static func decision(_ config: DerbyConfig, model: String,
                         health: [TargetKey: TargetHealth] = [:]) throws -> RoutingDecision {
        try Router().route(RoutingRequest(logicalModelName: model,
                                          requirements: CapabilityRequirements(required: [.text]),
                                          promptTokens: 100),
                           snapshot: snapshot(config, health: health))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Collects records and logs the executor emits.
final class RecordingSink: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [RequestRecord] = []
    private var _logs: [LogEntry] = []
    func record(_ record: RequestRecord) async { append(record) }
    func log(_ entry: LogEntry) async { append(entry) }
    private func append(_ r: RequestRecord) { lock.lock(); _records.append(r); lock.unlock() }
    private func append(_ e: LogEntry) { lock.lock(); _logs.append(e); lock.unlock() }
    var records: [RequestRecord] { lock.lock(); defer { lock.unlock() }; return _records }
    var logs: [LogEntry] { lock.lock(); defer { lock.unlock() }; return _logs }
    var last: RequestRecord? { records.last }
}


/// A secret store that behaves as if the Keychain were unavailable, so the
/// gateway's fail-closed behaviour can be exercised.
final class UnavailableSecretStore: SecretStore, @unchecked Sendable {
    struct Denied: Error {}
    public init() {}
    func set(_ value: String?, for ref: SecretRef) throws { throw Denied() }
    func get(_ ref: SecretRef) -> String? { nil }
    func delete(_ ref: SecretRef) throws {}
    func prune(keeping refs: [SecretRef]) {}
}
