import Foundation

public enum CanonicalFinishReason: String, Codable, Sendable, Hashable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case cancelled
    case error
    case other
}

public struct CanonicalUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    /// True when Derby derived these counts itself because the provider did not
    /// report any. Surfaced in the UI so approximate numbers are never passed
    /// off as measured ones.
    public var isEstimated: Bool

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0,
                cacheWriteTokens: Int = 0, reasoningTokens: Int = 0, isEstimated: Bool = false) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens; self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens; self.isEstimated = isEstimated
    }

    // Older stored records predate `isEstimated`; default it rather than failing.
    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cachedInputTokens, cacheWriteTokens, reasoningTokens, isEstimated
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }
    public var totalTokens: Int { inputTokens + outputTokens }
    public static let zero = CanonicalUsage()

    /// A rough count for providers that report nothing. Four characters per
    /// token is the usual English approximation.
    public static func estimated(promptTokens: Int, completionText: String, reasoningText: String = "") -> CanonicalUsage {
        CanonicalUsage(inputTokens: promptTokens,
                       outputTokens: max(1, (completionText.count + reasoningText.count) / 4),
                       reasoningTokens: reasoningText.isEmpty ? 0 : max(1, reasoningText.count / 4),
                       isEstimated: true)
    }

    public static func + (a: CanonicalUsage, b: CanonicalUsage) -> CanonicalUsage {
        CanonicalUsage(inputTokens: a.inputTokens + b.inputTokens,
                       outputTokens: a.outputTokens + b.outputTokens,
                       cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens,
                       cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
                       reasoningTokens: a.reasoningTokens + b.reasoningTokens)
    }
    public var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 }
}

public struct CanonicalResponse: Codable, Sendable {
    public var id: String
    /// The physical model that actually produced this response.
    public var model: String
    public var created: Date
    public var message: CanonicalMessage
    public var finishReason: CanonicalFinishReason
    public var usage: CanonicalUsage
    /// Provider payload retained for debugging when verbose logging is on.
    public var raw: JSONValue?

    public init(id: String, model: String, created: Date = Date(),
                message: CanonicalMessage,
                finishReason: CanonicalFinishReason = .stop,
                usage: CanonicalUsage = .zero,
                raw: JSONValue? = nil) {
        self.id = id; self.model = model; self.created = created
        self.message = message; self.finishReason = finishReason
        self.usage = usage; self.raw = raw
    }
}

public struct CanonicalEmbeddingResponse: Codable, Sendable {
    public var model: String
    public var vectors: [[Double]]
    public var usage: CanonicalUsage
    public init(model: String, vectors: [[Double]], usage: CanonicalUsage = .zero) {
        self.model = model; self.vectors = vectors; self.usage = usage
    }
}

/// Provider-independent stream events. Adapters translate their native SSE
/// dialect into this; the API layer translates it back out to the client's.
public enum CanonicalStreamEvent: Sendable {
    case start(id: String, model: String)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStart(index: Int, id: String, name: String)
    case toolCallArgumentsDelta(index: Int, delta: String)
    case usage(CanonicalUsage)
    case finish(CanonicalFinishReason)
    /// Opaque reasoning the provider issued. Never shown to the client; kept so
    /// the same lineage can continue from it.
    case reasoningArtifact(ReasoningArtifact)

    public var isContentBearing: Bool {
        switch self {
        case .textDelta(let t): return !t.isEmpty
        case .reasoningDelta(let t): return !t.isEmpty
        case .toolCallStart, .toolCallArgumentsDelta: return true
        default: return false
        }
    }
}

/// Accumulates stream events back into a complete response, so the executor can
/// record usage/history for streamed requests and the test console can show a
/// final message.
public struct StreamAccumulator: Sendable {
    public private(set) var id: String = ""
    public private(set) var model: String = ""
    public private(set) var text: String = ""
    public private(set) var reasoning: String = ""
    public private(set) var usage: CanonicalUsage = .zero
    public private(set) var finishReason: CanonicalFinishReason = .stop
    public private(set) var artifacts: [ReasoningArtifact] = []
    private var toolCalls: [Int: CanonicalToolCall] = [:]

    public init() {}

    public mutating func ingest(_ event: CanonicalStreamEvent) {
        switch event {
        case .start(let i, let m): id = i; model = m
        case .textDelta(let t): text += t
        case .reasoningDelta(let t): reasoning += t
        case .toolCallStart(let idx, let id, let name):
            var existing = toolCalls[idx] ?? CanonicalToolCall(id: id, name: name, argumentsJSON: "")
            if !id.isEmpty { existing.id = id }
            if !name.isEmpty { existing.name = name }
            toolCalls[idx] = existing
        case .toolCallArgumentsDelta(let idx, let d):
            // An empty id is filled in by the executor, which makes it unique.
            var existing = toolCalls[idx] ?? CanonicalToolCall(id: "", name: "", argumentsJSON: "")
            existing.argumentsJSON += d
            toolCalls[idx] = existing
        case .usage(let u): usage = u
        case .finish(let r): finishReason = r
        case .reasoningArtifact(let a): artifacts.append(a)
        }
    }

    public var orderedToolCalls: [CanonicalToolCall] {
        toolCalls.sorted { $0.key < $1.key }.map { $0.value }
    }

    public func makeResponse(fallbackModel: String) -> CanonicalResponse {
        var content: [CanonicalContent] = []
        if !text.isEmpty { content.append(.text(text)) }
        let msg = CanonicalMessage(role: .assistant, content: content,
                                   toolCalls: orderedToolCalls,
                                   reasoning: reasoning.isEmpty ? nil : reasoning,
                                   reasoningArtifacts: artifacts)
        return CanonicalResponse(id: id.isEmpty ? IDGenerator.requestID() : id,
                                 model: model.isEmpty ? fallbackModel : model,
                                 message: msg,
                                 finishReason: finishReason,
                                 usage: usage)
    }
}
