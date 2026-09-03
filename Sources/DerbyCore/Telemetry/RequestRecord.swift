import Foundation

public enum AttemptStatus: String, Sendable, Codable {
    case success, failed, skipped, cancelled, hedgeLost = "hedge_lost"
    public var displayName: String {
        switch self {
        case .success: return "SUCCESS"
        case .failed: return "FAILED"
        case .skipped: return "SKIPPED"
        case .cancelled: return "CANCELLED"
        case .hedgeLost: return "HEDGE LOST"
        }
    }
}

/// One provider invocation inside a request.
public struct AttemptRecord: Sendable, Codable, Identifiable, Hashable {
    public var id: String                 // attempt_1, attempt_2, …
    public var index: Int
    public var providerID: UUID
    public var providerName: String
    public var providerKind: String
    public var modelID: String
    public var targetLabel: String
    public var status: AttemptStatus
    public var startedAt: Date
    public var durationSeconds: Double
    public var timeToFirstTokenSeconds: Double?
    public var httpStatus: Int?
    public var failureKind: FailureKind?
    public var errorMessage: String?
    public var retryCount: Int
    public var usage: CanonicalUsage
    public var costUSD: Double
    public var circuitState: CircuitState
    public var routingScore: Double?

    public init(id: String, index: Int, providerID: UUID, providerName: String, providerKind: String,
                modelID: String, targetLabel: String, status: AttemptStatus, startedAt: Date,
                durationSeconds: Double, timeToFirstTokenSeconds: Double? = nil, httpStatus: Int? = nil,
                failureKind: FailureKind? = nil, errorMessage: String? = nil, retryCount: Int = 0,
                usage: CanonicalUsage = .zero, costUSD: Double = 0,
                circuitState: CircuitState = .closed, routingScore: Double? = nil) {
        self.id = id; self.index = index; self.providerID = providerID
        self.providerName = providerName; self.providerKind = providerKind
        self.modelID = modelID; self.targetLabel = targetLabel; self.status = status
        self.startedAt = startedAt; self.durationSeconds = durationSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds; self.httpStatus = httpStatus
        self.failureKind = failureKind; self.errorMessage = errorMessage; self.retryCount = retryCount
        self.usage = usage; self.costUSD = costUSD; self.circuitState = circuitState
        self.routingScore = routingScore
    }

    public var summaryLine: String {
        var s = "\(index + 1). \(providerName) · \(modelID)"
        s += "\n   \(status.displayName)"
        if let k = failureKind { s += " — \(k.rawValue)" }
        if let http = httpStatus { s += " (HTTP \(http))" }
        if let t = timeToFirstTokenSeconds { s += "\n   TTFT: \(t.msString)" }
        s += "\n   Total: \(durationSeconds.msString)"
        return s
    }
}

/// The complete story of one client request.
public struct RequestRecord: Sendable, Codable, Identifiable, Hashable {
    public var id: String                     // req_01J…
    public var createdAt: Date
    public var logicalModel: String
    public var requestedModel: String
    public var clientName: String
    public var dialect: String
    public var streaming: Bool
    public var succeeded: Bool
    public var finalProviderName: String?
    public var finalProviderID: UUID?
    public var finalModelID: String?
    public var totalSeconds: Double
    public var timeToFirstTokenSeconds: Double?
    public var usage: CanonicalUsage
    public var costUSD: Double
    public var attempts: [AttemptRecord]
    public var evaluations: [CandidateEvaluation]
    public var exclusions: [ExclusionRecord]
    public var routingStrategy: String
    public var routingExplanation: String
    public var failureKind: FailureKind?
    public var errorMessage: String?
    public var retryCount: Int
    public var failoverCount: Int
    public var httpStatus: Int
    /// Only populated when prompt logging is enabled.
    public var promptExcerpt: String?
    public var responseExcerpt: String?

    public init(id: String = IDGenerator.requestID(), createdAt: Date = Date(),
                logicalModel: String = "", requestedModel: String = "", clientName: String = "unknown",
                dialect: String = "chat.completions", streaming: Bool = false, succeeded: Bool = false,
                finalProviderName: String? = nil, finalProviderID: UUID? = nil, finalModelID: String? = nil,
                totalSeconds: Double = 0, timeToFirstTokenSeconds: Double? = nil,
                usage: CanonicalUsage = .zero, costUSD: Double = 0,
                attempts: [AttemptRecord] = [], evaluations: [CandidateEvaluation] = [],
                exclusions: [ExclusionRecord] = [], routingStrategy: String = "",
                routingExplanation: String = "", failureKind: FailureKind? = nil,
                errorMessage: String? = nil, retryCount: Int = 0, failoverCount: Int = 0,
                httpStatus: Int = 200, promptExcerpt: String? = nil, responseExcerpt: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.logicalModel = logicalModel
        self.requestedModel = requestedModel; self.clientName = clientName; self.dialect = dialect
        self.streaming = streaming; self.succeeded = succeeded
        self.finalProviderName = finalProviderName; self.finalProviderID = finalProviderID
        self.finalModelID = finalModelID; self.totalSeconds = totalSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds; self.usage = usage; self.costUSD = costUSD
        self.attempts = attempts; self.evaluations = evaluations; self.exclusions = exclusions
        self.routingStrategy = routingStrategy; self.routingExplanation = routingExplanation
        self.failureKind = failureKind; self.errorMessage = errorMessage
        self.retryCount = retryCount; self.failoverCount = failoverCount; self.httpStatus = httpStatus
        self.promptExcerpt = promptExcerpt; self.responseExcerpt = responseExcerpt
    }

    /// The inspector's headline text.
    public var inspectorSummary: String {
        var lines = ["Request", id, "",
                     "Logical Model:", logicalModel, "",
                     "Final Provider:", finalProviderName ?? "—", "",
                     "Final Model:", finalModelID ?? "—", "",
                     "Attempts:"]
        for a in attempts { lines.append(a.summaryLine); lines.append("") }
        lines.append("Input Tokens: \(usage.inputTokens)")
        lines.append("Output Tokens: \(usage.outputTokens)")
        lines.append("Cost: \(costUSD.usdString)")
        lines.append("")
        lines.append("Routing Reason:")
        lines.append(routingExplanation)
        return lines.joined(separator: "\n")
    }
}

public struct LogEntry: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var at: Date
    public var level: LogLevel
    public var category: String
    public var message: String
    public var requestID: String?
    public var fields: [String: String]

    public init(level: LogLevel, category: String, message: String,
                requestID: String? = nil, fields: [String: String] = [:], at: Date = Date()) {
        self.id = IDGenerator.ulid(now: at)
        self.at = at
        self.level = level
        self.category = category
        self.message = SecretRedactor.redact(message)
        self.requestID = requestID
        self.fields = fields.mapValues { SecretRedactor.redact($0) }
    }

    public var formatted: String {
        let ts = ISO8601DateFormatter().string(from: at)
        var s = "\(ts) [\(level.rawValue.uppercased())] \(category): \(message)"
        if let r = requestID { s += " request_id=\(r)" }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { s += " \(k)=\(v)" }
        return s
    }
}

/// Where finished requests and log lines go. Abstracted so the executor has no
/// dependency on storage, and tests can assert on what was recorded.
public protocol TelemetrySink: Sendable {
    func record(_ record: RequestRecord) async
    func log(_ entry: LogEntry) async
}

public struct NullTelemetrySink: TelemetrySink {
    public init() {}
    public func record(_ record: RequestRecord) async {}
    public func log(_ entry: LogEntry) async {}
}
