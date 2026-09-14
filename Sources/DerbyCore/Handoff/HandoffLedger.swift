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
/// finds it again. It is bounded by count, bytes and age, and a miss simply
/// means an earlier turn is unattributed.
///
/// With a store attached, what replaying an answer needs — its opaque
/// reasoning, who wrote it, the conversation it belongs to — also survives a
/// restart. Plain-text reasoning, which local models write, stays in memory.
public actor HandoffLedger {
    public struct Limits: Sendable {
        public var maxEntries: Int
        public var maxBytes: Int
        public var maxAge: TimeInterval
        public init(maxEntries: Int = 4_096, maxBytes: Int = 24_000_000, maxAge: TimeInterval = 6 * 3600) {
            self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.maxAge = maxAge
        }
    }

    /// An entry as a store keeps it.
    public struct Stored: Codable, Sendable {
        public var key: String
        public var origin: MessageOrigin
        public var artifacts: [ReasoningArtifact]
        public var toolCallIDs: [String]
        public var conversation: String?
        public var lastUsedAt: Date
        /// Digest of the answer alone, when it was long enough to identify
        /// itself. Absent in rows written before this index existed.
        public var answerIndex: String?
    }

    private struct Entry {
        var origin: MessageOrigin
        var reasoning: String?
        var artifacts: [ReasoningArtifact]
        var lastUsedAt: Date
        var bytes: Int
        var toolCallIDs: [String]
        /// `CanonicalRequest.conversationKey` of the request this answered.
        var conversation: String?
        var answerIndex: String?
    }

    private let limits: Limits
    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var byToolCall: [String: String] = [:]
    /// Answers long enough to identify themselves without the turn they
    /// answered, for clients that rewrite their earlier turns.
    private var byAnswer: [String: String] = [:]
    private var totalBytes = 0
    private var store: (any HandoffLedgerStore)?

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var count: Int { entries.count }

    public func removeAll() {
        entries.removeAll(); order.removeAll(); byToolCall.removeAll(); byAnswer.removeAll(); totalBytes = 0
        store?.removeAll()
    }

    // MARK: - Persistence

    /// Keeps the ledger in `store` from now on, starting from what it holds.
    public func attach(store: any HandoffLedgerStore, now: Date = Date()) {
        self.store = store
        for stored in store.load().sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) where entries[stored.key] == nil {
            insert(Entry(origin: stored.origin, reasoning: nil, artifacts: stored.artifacts,
                         lastUsedAt: stored.lastUsedAt, bytes: Self.bytes(reasoning: nil, artifacts: stored.artifacts),
                         toolCallIDs: stored.toolCallIDs, conversation: stored.conversation,
                         answerIndex: stored.answerIndex),
                   key: stored.key)
        }
        evict(now: now)
    }

    // MARK: - Recording

    /// Remembers that `origin` wrote `message` in answer to `request`.
    public func record(request: CanonicalRequest, response message: CanonicalMessage,
                       origin: MessageOrigin, at date: Date = Date()) {
        let key = Self.fingerprint(precedingUserText: Self.lastUserText(in: request.messages[...]),
                                   message: message)
        let reasoning = message.reasoning?.isEmpty == false ? message.reasoning : nil
        remove(key, persisting: false)
        let entry = Entry(origin: origin, reasoning: reasoning, artifacts: message.reasoningArtifacts,
                          lastUsedAt: date,
                          bytes: Self.bytes(reasoning: reasoning, artifacts: message.reasoningArtifacts),
                          toolCallIDs: message.toolCalls.map(\.id), conversation: request.conversationKey,
                          answerIndex: Self.answerIndex(for: message))
        insert(entry, key: key)
        store?.save(Stored(key: key, origin: origin, artifacts: entry.artifacts, toolCallIDs: entry.toolCallIDs,
                           conversation: entry.conversation, lastUsedAt: date,
                           answerIndex: entry.answerIndex))
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
        var used: [String] = []
        var conversation: String?
        for i in result.messages.indices {
            let message = result.messages[i]
            if message.role == .user { lastUserText = message.joinedText; continue }
            guard message.role == .assistant else { continue }

            var key = message.toolCalls.compactMap { byToolCall[$0.id] }.first
            if key == nil {
                let pair = Self.fingerprint(precedingUserText: lastUserText, message: message)
                // Compaction rewrites earlier turns — a summary in place of the
                // history, a long tool result trimmed — which breaks the pair
                // even where the answer itself came back untouched. An answer
                // this long identifies itself.
                key = entries[pair] != nil ? pair : Self.answerIndex(for: message).flatMap { byAnswer[$0] }
            }
            guard let key, let entry = entries[key] else { continue }
            guard now.timeIntervalSince(entry.lastUsedAt) <= limits.maxAge else { remove(key); continue }
            // The age limit is for conversations nobody continues: one still in
            // use keeps its reasoning however long it runs.
            touch(key)
            entries[key]?.lastUsedAt = now
            used.append(key)
            // The latest recorded answer says which conversation this is, even
            // after the client has rewritten how the history begins.
            if let written = entry.conversation { conversation = written }

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
        store?.touch(used, at: now)
        if let conversation { result.continuesConversation = conversation }
        return result
    }

    /// The model that wrote the most recent attributed answer, for routing's
    /// continuity preference.
    public static func conversationLineage(of request: CanonicalRequest) -> ModelLineage? {
        request.messages.last { $0.role == .assistant && $0.origin != nil }?.origin?.lineage
    }

    /// The account that wrote the most recent attributed answer: where the
    /// conversation's reasoning and cached prompt are.
    public static func conversationAccount(of request: CanonicalRequest) -> UUID? {
        request.messages.last { $0.role == .assistant && $0.origin != nil }?.origin?.accountID
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

    /// Shortest answer trusted to identify itself. Short answers repeat across
    /// conversations ("Done."), so they are only ever found with the turn they
    /// answered; this much prose does not collide in a six-hour window.
    static let distinctiveAnswerLength = 200

    /// A digest of the answer alone, for answers long enough to be unmistakable.
    static func answerIndex(for message: CanonicalMessage) -> String? {
        let text = ReasoningMarkup.answerText(message.joinedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= distinctiveAnswerLength else { return nil }
        return HandoffHash.hex("answer\u{1F}" + text)
    }

    // MARK: - Bookkeeping

    private func insert(_ entry: Entry, key: String) {
        entries[key] = entry
        order.append(key)
        totalBytes += entry.bytes
        for id in entry.toolCallIDs where !id.isEmpty { byToolCall[id] = key }
        if let index = entry.answerIndex { byAnswer[index] = key }
    }

    private static func bytes(reasoning: String?, artifacts: [ReasoningArtifact]) -> Int {
        (reasoning?.utf8.count ?? 0) + artifacts.reduce(0) { $0 + $1.byteCount } + 256
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func remove(_ key: String, persisting: Bool = true) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        for id in entry.toolCallIDs where byToolCall[id] == key { byToolCall.removeValue(forKey: id) }
        if let index = entry.answerIndex, byAnswer[index] == key { byAnswer.removeValue(forKey: index) }
        if persisting { store?.remove([key]) }
    }

    private func evict(now: Date) {
        while let oldest = order.first,
              entries.count > limits.maxEntries || totalBytes > limits.maxBytes
                || (entries[oldest].map { now.timeIntervalSince($0.lastUsedAt) > limits.maxAge } ?? true) {
            remove(oldest)
            if entries[oldest] == nil, order.first == oldest { order.removeFirst() }
        }
    }
}
