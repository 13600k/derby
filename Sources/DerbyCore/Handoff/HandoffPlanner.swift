import Foundation
import CryptoKit

/// The model a conversation is being handed to, as the handoff planner needs it.
public struct HandoffTarget: Sendable {
    public var modelID: String
    public var providerKind: ProviderKind
    public var accountID: UUID
    public var lineage: ModelLineage
    public var traits: LineageTraits

    public init(modelID: String, providerKind: ProviderKind, accountID: UUID, familyHint: String? = nil) {
        self.modelID = modelID
        self.providerKind = providerKind
        self.accountID = accountID
        self.lineage = ModelLineage.parse(modelID, familyHint: familyHint)
        self.traits = LineageTraits.for(lineage)
    }

    public init(target: ResolvedTarget) {
        self.init(modelID: target.modelID, providerKind: target.account.kind,
                  accountID: target.account.id, familyHint: target.model.profile?.family)
    }
}

/// What Derby did to carry a conversation to the model that answered it.
///
/// Reported like compaction: in `x_derby.handoff`, on the `x-derby-handoff`
/// header, in the routing explanation and in request history. A client whose
/// conversation changed models should be able to tell what the new model did
/// and did not receive.
public struct HandoffRecord: Codable, Sendable, Hashable {
    public var targetModel: String
    public var targetLineage: String
    /// Models that wrote earlier answers, oldest first, when Derby knows them.
    public var origins: [String]
    /// How the most recent known author relates to the target.
    public var affinity: LineageAffinity
    /// Earlier answers whose reasoning reached the target.
    public var reasoningCarried: Int
    /// Earlier answers in the target's reasoning window whose reasoning could
    /// not be carried — written by a different family, or not replayable here.
    public var reasoningWithheld: Int
    public var signedReasoningCarried: Int
    public var signedReasoningWithheld: Int
    public var toolCallIDsRewritten: Int
    /// Assistant turns Derby has no record of writing.
    public var unattributedTurns: Int
    /// Structural repairs and target-specific adjustments, in words.
    public var adjustments: [String]

    public init(targetModel: String, targetLineage: String, origins: [String] = [],
                affinity: LineageAffinity = .unknown, reasoningCarried: Int = 0,
                reasoningWithheld: Int = 0, signedReasoningCarried: Int = 0,
                signedReasoningWithheld: Int = 0, toolCallIDsRewritten: Int = 0,
                unattributedTurns: Int = 0, adjustments: [String] = []) {
        self.targetModel = targetModel; self.targetLineage = targetLineage; self.origins = origins
        self.affinity = affinity; self.reasoningCarried = reasoningCarried
        self.reasoningWithheld = reasoningWithheld; self.signedReasoningCarried = signedReasoningCarried
        self.signedReasoningWithheld = signedReasoningWithheld
        self.toolCallIDsRewritten = toolCallIDsRewritten; self.unattributedTurns = unattributedTurns
        self.adjustments = adjustments
    }

    private enum CodingKeys: String, CodingKey {
        case targetModel, targetLineage, origins, affinity, reasoningCarried, reasoningWithheld
        case signedReasoningCarried, signedReasoningWithheld, toolCallIDsRewritten, unattributedTurns, adjustments
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetModel = try c.decodeIfPresent(String.self, forKey: .targetModel) ?? ""
        targetLineage = try c.decodeIfPresent(String.self, forKey: .targetLineage) ?? ""
        origins = try c.decodeIfPresent([String].self, forKey: .origins) ?? []
        affinity = (try? c.decode(LineageAffinity.self, forKey: .affinity)) ?? .unknown
        reasoningCarried = try c.decodeIfPresent(Int.self, forKey: .reasoningCarried) ?? 0
        reasoningWithheld = try c.decodeIfPresent(Int.self, forKey: .reasoningWithheld) ?? 0
        signedReasoningCarried = try c.decodeIfPresent(Int.self, forKey: .signedReasoningCarried) ?? 0
        signedReasoningWithheld = try c.decodeIfPresent(Int.self, forKey: .signedReasoningWithheld) ?? 0
        toolCallIDsRewritten = try c.decodeIfPresent(Int.self, forKey: .toolCallIDsRewritten) ?? 0
        unattributedTurns = try c.decodeIfPresent(Int.self, forKey: .unattributedTurns) ?? 0
        adjustments = try c.decodeIfPresent([String].self, forKey: .adjustments) ?? []
    }

    /// The model that answered the turn before this one, when Derby knows.
    public var previousModel: String? { origins.last }

    /// Whether the conversation changed model, or anything had to change to
    /// carry it. An unchanged same-model turn with nothing to repair is not.
    public var isNotable: Bool {
        let changedModel = previousModel.map { $0 != targetModel } ?? false
        return changedModel || reasoningWithheld > 0 || signedReasoningWithheld > 0
            || toolCallIDsRewritten > 0 || !adjustments.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if let from = previousModel, from != targetModel {
            parts.append("continued from \(from) (\(affinity.displayName))")
        }
        let carried = reasoningCarried + signedReasoningCarried
        if carried > 0 { parts.append("carried reasoning from \(plural(carried, "earlier step"))") }
        let withheld = reasoningWithheld + signedReasoningWithheld
        if withheld > 0 {
            parts.append("withheld reasoning from \(plural(withheld, "earlier step")) this model cannot read")
        }
        if toolCallIDsRewritten > 0 {
            parts.append("rewrote \(plural(toolCallIDsRewritten, "tool call id")) to the format \(targetModel) requires")
        }
        parts += adjustments
        return parts.isEmpty ? "no changes needed" : parts.joined(separator: "; ")
    }
}

/// Adapts a normalized conversation to one target, per attempt.
///
/// Two principles decide what happens to what earlier models left behind:
///
/// - **Reasoning is carried only to its own lineage.** A model's chain of
///   thought is written in its own idiom and, for the major APIs, sealed so
///   only its issuer can read it. Handed to the same weights (a q4 copy of the
///   fp8 model that wrote it) it continues exactly where it stopped; handed to
///   a different family it would be read as something the assistant said. So
///   it goes where it can be read and nowhere else — and only within the
///   window that family's own template reads back.
/// - **Structure is made to fit the target.** Tool call ids, system message
///   placement, strict alternation and media in tool results all follow the
///   receiving model's rules, so nothing is rejected or silently dropped for a
///   reason unrelated to what was said.
public enum HandoffPlanner {
    public struct Outcome: Sendable {
        public var request: CanonicalRequest
        public var record: HandoffRecord
    }

    public static func plan(_ request: CanonicalRequest, for target: HandoffTarget,
                            policy: HandoffPolicy = .default, repairs: [String] = []) -> Outcome {
        var messages = request.messages
        var record = HandoffRecord(targetModel: target.modelID, targetLineage: target.lineage.label)
        var adjustments = repairs
        let family = target.providerKind.adapterFamily
        let carriesText = !target.providerKind.reasoningReplayFields.isEmpty
        let lastUser = messages.lastIndex { $0.role == .user } ?? -1
        var lastOrigin: MessageOrigin?
        var sentinelCalls = 0

        for i in messages.indices where messages[i].role == .assistant {
            let origin = messages[i].origin
            if let origin {
                record.origins.removeAll { $0 == origin.modelID }
                record.origins.append(origin.modelID)
                lastOrigin = origin
            } else {
                record.unattributedTurns += 1
            }
            let affinity = origin.map { $0.lineage.affinity(with: target.lineage) } ?? .unknown
            let inActiveLoop = i > lastUser

            if let reasoning = messages[i].reasoning, !reasoning.isEmpty {
                let inWindow: Bool
                switch target.traits.reasoningReplay {
                case .none: inWindow = false
                case .activeToolLoop: inWindow = inActiveLoop
                case .allTurnsWithTools: inWindow = request.usesTools
                }
                if policy.replayReasoning, carriesText, inWindow, affinity.sharesReasoningFormat {
                    record.reasoningCarried += 1
                } else {
                    messages[i].reasoning = nil
                    let signed = messages[i].reasoningArtifacts.contains { family.reasoningArtifactFormats.contains($0.format) }
                    // Outside the window the target would not read it even from
                    // its own lineage, so that is not a loss worth reporting.
                    if (inWindow || inActiveLoop) && !signed { record.reasoningWithheld += 1 }
                }
            }

            if !messages[i].reasoningArtifacts.isEmpty {
                let all = messages[i].reasoningArtifacts
                let kept = policy.replayReasoning && inActiveLoop
                    ? all.filter { accepts($0, origin: origin, affinity: affinity, target: target) }
                    : []
                if inActiveLoop {
                    record.signedReasoningCarried += kept.isEmpty ? 0 : 1
                    record.signedReasoningWithheld += kept.isEmpty ? 1 : 0
                }
                messages[i].reasoningArtifacts = kept
            }

            // Gemini 3 refuses a function call in the current turn that carries
            // no thought signature. A call another model made has none to give,
            // so it gets the value Google documents for exactly this case.
            if family == .google, target.lineage.family == "gemini", (target.lineage.majorVersion ?? 0) >= 3,
               inActiveLoop, let first = messages[i].toolCalls.first,
               !messages[i].reasoningArtifacts.contains(where: {
                   $0.format == .geminiThoughtSignature && $0.toolCallID == first.id }) {
                messages[i].reasoningArtifacts.append(ReasoningArtifact(
                    format: .geminiThoughtSignature, payload: ReasoningArtifact.geminiUnsignedCallSentinel,
                    toolCallID: first.id))
                sentinelCalls += 1
            }
        }
        record.affinity = lastOrigin.map { $0.lineage.affinity(with: target.lineage) } ?? .unknown
        if sentinelCalls > 0 {
            adjustments.append("marked \(plural(sentinelCalls, "tool call turn")) from another model so Gemini 3 accepts them")
        }

        if !target.providerKind.acceptsDeveloperRole {
            for i in messages.indices where messages[i].role == .developer { messages[i].role = .system }
        }
        placeSystemMessages(&messages, target: target, adjustments: &adjustments)
        if target.traits.requiresAlternation {
            let joined = joinConsecutiveUserMessages(&messages)
            if joined > 0 {
                adjustments.append("combined \(plural(joined, "back-to-back user message")) (\(target.lineage.family) requires strict alternation)")
            }
        }
        record.toolCallIDsRewritten = rewriteToolCallIDs(&messages, target: target)
        if !family.toolResultsAcceptImages {
            let moved = relocateToolResultImages(&messages)
            if moved > 0 {
                adjustments.append("moved images from \(plural(moved, "tool result")) into a user message, since tool results cannot carry images here")
            }
        }

        record.adjustments = adjustments
        var out = request
        out.messages = messages
        return Outcome(request: out, record: record)
    }

    /// Whether an opaque reasoning artifact can be read by this target.
    static func accepts(_ artifact: ReasoningArtifact, origin: MessageOrigin?, affinity: LineageAffinity,
                        target: HandoffTarget) -> Bool {
        guard target.providerKind.adapterFamily.reasoningArtifactFormats.contains(artifact.format) else { return false }
        switch artifact.format {
        case .anthropicThinking, .anthropicRedactedThinking:
            // Claude reads its own blocks and those of earlier Claude models, and
            // the API drops the rest without error.
            return target.lineage.family == "claude" && origin?.lineage.family == "claude"
        case .openAIEncryptedReasoning:
            // Encrypted for the account that received it.
            return artifact.originAccount == target.accountID && affinity.sharesReasoningFormat
        case .geminiThoughtSignature:
            if artifact.payload == ReasoningArtifact.geminiUnsignedCallSentinel {
                return target.lineage.family == "gemini"
            }
            return artifact.originAccount == target.accountID && affinity.sharesReasoningFormat
        }
    }

    // MARK: - Structure

    static func placeSystemMessages(_ messages: inout [CanonicalMessage], target: HandoffTarget,
                                    adjustments: inout [String]) {
        let isInstruction: (CanonicalMessage) -> Bool = { $0.role == .system || $0.role == .developer }
        if target.traits.foldsSystemIntoFirstUser {
            let instructions = messages.filter(isInstruction).map(\.joinedText).filter { !$0.isEmpty }
            guard !instructions.isEmpty, let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
            var user = messages[firstUser]
            user.content = ConversationNormalizer.joinContent([.text(instructions.joined(separator: "\n\n"))], user.content)
            messages[firstUser] = user
            messages.removeAll(where: isInstruction)
            adjustments.append("folded system instructions into the first user message (\(target.lineage.family) has no system role)")
        } else if target.traits.systemMessagesLeadOnly {
            guard let firstOther = messages.firstIndex(where: { !isInstruction($0) }),
                  messages[firstOther...].contains(where: isInstruction) else { return }
            let late = messages[firstOther...].filter(isInstruction).count
            let text = messages.filter(isInstruction).map(\.joinedText).filter { !$0.isEmpty }
            messages.removeAll(where: isInstruction)
            messages.insert(.system(text.joined(separator: "\n\n")), at: 0)
            adjustments.append("moved \(plural(late, "system message")) to the start (\(target.lineage.family) accepts instructions only there)")
        }
    }

    static func joinConsecutiveUserMessages(_ messages: inout [CanonicalMessage]) -> Int {
        var out: [CanonicalMessage] = []
        var joined = 0
        for message in messages {
            if message.role == .user, var last = out.last, last.role == .user {
                last.content = ConversationNormalizer.joinContent(last.content, message.content)
                out[out.count - 1] = last
                joined += 1
            } else {
                out.append(message)
            }
        }
        messages = out
        return joined
    }

    /// Rewrites ids the target would reject, deterministically, so a call and
    /// its result always agree and the same history renders the same way on
    /// every request.
    static func rewriteToolCallIDs(_ messages: inout [CanonicalMessage], target: HandoffTarget) -> Int {
        let rewrite: (String) -> String?
        if target.traits.requiresNineCharToolIDs {
            rewrite = { id in
                id.range(of: "^[A-Za-z0-9]{9}$", options: .regularExpression) != nil ? nil : HandoffHash.base62(id, length: 9)
            }
        } else if target.providerKind.adapterFamily.restrictsToolCallIDAlphabet {
            rewrite = { id in
                id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
                    ? nil : "call_" + HandoffHash.base62(id, length: 24)
            }
        } else {
            return 0
        }
        var mapping: [String: String] = [:]
        func mapped(_ id: String) -> String {
            if let known = mapping[id] { return known }
            let value = rewrite(id) ?? id
            mapping[id] = value
            return value
        }
        for i in messages.indices {
            for j in messages[i].toolCalls.indices {
                messages[i].toolCalls[j].id = mapped(messages[i].toolCalls[j].id)
            }
            if let id = messages[i].toolCallID { messages[i].toolCallID = mapped(id) }
            for j in messages[i].reasoningArtifacts.indices {
                if let id = messages[i].reasoningArtifacts[j].toolCallID {
                    messages[i].reasoningArtifacts[j].toolCallID = mapped(id)
                }
            }
        }
        return mapping.filter { $0.key != $0.value }.count
    }

    /// A tool that returned a screenshot on a protocol whose tool results are
    /// text only: the image follows as the user's, rather than vanishing.
    static func relocateToolResultImages(_ messages: inout [CanonicalMessage]) -> Int {
        var out: [CanonicalMessage] = []
        var pending: [CanonicalContent] = []
        var moved = 0
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(CanonicalMessage(role: .user, content: [.text("Images returned by the tool calls above:")] + pending))
            pending.removeAll()
        }
        for message in messages {
            if message.role == .tool {
                var result = message
                let images = result.content.filter(\.isImage)
                if !images.isEmpty {
                    result.content.removeAll(where: \.isImage)
                    if result.joinedText.isEmpty { result.content.append(.text("(returned \(plural(images.count, "image")), attached below)")) }
                    pending += images
                    moved += 1
                }
                out.append(result)
            } else {
                flush()
                out.append(message)
            }
        }
        flush()
        messages = out
        return moved
    }
}

/// Stable short hashes for rewritten identifiers.
enum HandoffHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func base62(_ input: String, length: Int) -> String {
        var out = ""
        for byte in SHA256.hash(data: Data(input.utf8)) {
            out.append(alphabet[Int(byte) % alphabet.count])
            if out.count == length { break }
        }
        return out
    }

    static func hex(_ input: String, length: Int = 32) -> String {
        String(SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}
