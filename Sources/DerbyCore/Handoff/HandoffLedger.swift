import Foundation

extension MessageOrigin {
    public init(target: ResolvedTarget) {
        self.init(modelID: target.modelID, providerKind: target.account.kind.rawValue,
                  accountID: target.account.id, lineage: target.lineage)
    }
}

/// Remembers which model wrote each answer Derby returned, and the reasoning
/// that came with it.
///
/// Derby is stateless per request, and its clients speak a dialect with no
/// room for signed or encrypted reasoning, so what a model thought before
/// calling a tool never comes back on the next turn. Without it Claude and
/// GPT lose the reasoning that chose the tool, Gemini 3 refuses the call, and
/// Derby cannot even tell whether the model about to answer is the one that
/// wrote the history.
///
/// The ledger closes that gap without keeping a session: when an answer goes
/// out it is fingerprinted — the user message it answered, its text, its tool
/// calls — and when a client sends that answer back as history, the fingerprint
/// finds it again. Nothing is persisted; it lives in memory, bounded by count,
/// bytes and age, and a miss simply means an earlier turn is unattributed.
public actor HandoffLedger {
    public struct Limits: Sendable {
        public var maxEntries: Int
        public var maxBytes: Int
        public var maxAge: TimeInterval
        public init(maxEntries: Int = 4_096, maxBytes: Int = 24_000_000, maxAge: TimeInterval = 6 * 3600) {
            self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.maxAge = maxAge
        }
    }

    private struct Entry {
        var origin: MessageOrigin
        var reasoning: String?
        var artifacts: [ReasoningArtifact]
        var recordedAt: Date
        var bytes: Int
        var toolCallIDs: [String]
    }

    private let limits: Limits
    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var byToolCall: [String: String] = [:]
    private var totalBytes = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var count: Int { entries.count }

    public func removeAll() {
        entries.removeAll(); order.removeAll(); byToolCall.removeAll(); totalBytes = 0
    }

    // MARK: - Recording

    /// Remembers that `origin` wrote `message` in answer to `request`.
    public func record(request: CanonicalRequest, response message: CanonicalMessage,
                       origin: MessageOrigin, at date: Date = Date()) {
        let key = Self.fingerprint(precedingUserText: Self.lastUserText(in: request.messages[...]),
                                   message: message)
        let reasoning = message.reasoning?.isEmpty == false ? message.reasoning : nil
        let bytes = (reasoning?.utf8.count ?? 0) + message.reasoningArtifacts.reduce(0) { $0 + $1.byteCount } + 256
        remove(key)
        let entry = Entry(origin: origin, reasoning: reasoning, artifacts: message.reasoningArtifacts,
                          recordedAt: date, bytes: bytes, toolCallIDs: message.toolCalls.map(\.id))
        entries[key] = entry
        order.append(key)
        totalBytes += bytes
        for id in entry.toolCallIDs where !id.isEmpty { byToolCall[id] = key }
        evict(now: date)
    }

    // MARK: - Restoring

    /// Marks each assistant turn in `request` with the model that wrote it, and
    /// restores the reasoning the client could not carry back.
    ///
    /// Anything the client sent itself wins: restored reasoning only fills a
    /// turn that arrived without any.
    public func annotate(_ request: CanonicalRequest, now: Date = Date()) -> CanonicalRequest {
        guard !entries.isEmpty else { return request }
        var result = request
        var lastUserText = ""
        for i in result.messages.indices {
            let message = result.messages[i]
            if message.role == .user { lastUserText = message.joinedText; continue }
            guard message.role == .assistant else { continue }

            var key = message.toolCalls.compactMap { byToolCall[$0.id] }.first
            if key == nil { key = Self.fingerprint(precedingUserText: lastUserText, message: message) }
            guard let key, let entry = entries[key] else { continue }
            guard now.timeIntervalSince(entry.recordedAt) <= limits.maxAge else { remove(key); continue }
            touch(key)

            if result.messages[i].origin == nil { result.messages[i].origin = entry.origin }
            if result.messages[i].reasoning?.isEmpty ?? true, let reasoning = entry.reasoning {
                result.messages[i].reasoning = reasoning
            }
            if result.messages[i].reasoningArtifacts.isEmpty {
                result.messages[i].reasoningArtifacts = entry.artifacts
            } else {
                // A client that kept an artifact itself (Responses reasoning
                // items) cannot say which account issued it; the ledger can.
                for j in result.messages[i].reasoningArtifacts.indices
                where result.messages[i].reasoningArtifacts[j].originAccount == nil {
                    let payload = result.messages[i].reasoningArtifacts[j].payload
                    if let known = entry.artifacts.first(where: { $0.payload == payload }) {
                        result.messages[i].reasoningArtifacts[j].originAccount = known.originAccount
                        result.messages[i].reasoningArtifacts[j].originModel = known.originModel
                    }
                }
            }
        }
        return result
    }

    /// The model that wrote the most recent attributed answer, for routing's
    /// continuity preference.
    public static func conversationLineage(of request: CanonicalRequest) -> ModelLineage? {
        request.messages.last { $0.role == .assistant && $0.origin != nil }?.origin?.lineage
    }

    // MARK: - Fingerprints

    /// Identifies an answer by what it answered and what it said. The user
    /// message is part of the key so a short answer ("Done.") in one
    /// conversation can never be mistaken for the same words in another.
    static func fingerprint(precedingUserText: String, message: CanonicalMessage) -> String {
        let calls = message.toolCalls.map { "\($0.id)|\($0.name)" }.joined(separator: ",")
        let material = [
            precedingUserText.trimmingCharacters(in: .whitespacesAndNewlines),
            ReasoningMarkup.answerText(message.joinedText),
            calls,
        ].joined(separator: "\u{1F}")
        return HandoffHash.hex(material)
    }

    static func lastUserText(in messages: ArraySlice<CanonicalMessage>) -> String {
        messages.last { $0.role == .user }?.joinedText ?? ""
    }

    // MARK: - Bookkeeping

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        for id in entry.toolCallIDs where byToolCall[id] == key { byToolCall.removeValue(forKey: id) }
    }

    private func evict(now: Date) {
        while let oldest = order.first,
              entries.count > limits.maxEntries || totalBytes > limits.maxBytes
                || (entries[oldest].map { now.timeIntervalSince($0.recordedAt) > limits.maxAge } ?? true) {
            remove(oldest)
            if entries[oldest] == nil, order.first == oldest { order.removeFirst() }
        }
    }
}
