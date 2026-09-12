import Foundation

/// Puts a conversation into the shape every provider accepts, before any one
/// provider is involved.
///
/// Histories are written by whichever models answered earlier, stored by the
/// client, and sent back verbatim. A shape one provider tolerated is often one
/// the next rejects outright: a tool result that no longer follows its call, an
/// answer split across two assistant messages, reasoning left inline in
/// `<think>` tags. Fixing that here, once, means the model the conversation
/// moves to sees the same conversation the previous one did.
///
/// Every change is reported. None of them alters what anyone said.
public enum ConversationNormalizer {
    public struct Outcome: Sendable {
        public var request: CanonicalRequest
        /// What changed, in words. Empty for an already well-formed conversation.
        public var repairs: [String]
    }

    /// Stands in for a tool result that never came back, where a provider
    /// requires every call to be answered before the conversation continues.
    public static let missingResultText = "No result was recorded for this tool call."

    public static func normalize(_ request: CanonicalRequest) -> Outcome {
        var messages = request.messages
        var repairs: [String] = []

        let extracted = extractInlineReasoning(&messages)
        if extracted > 0 {
            repairs.append("moved inline <think> reasoning out of \(plural(extracted, "earlier answer"))")
        }

        let merged = mergeConsecutiveAssistants(&messages)
        if merged > 0 {
            repairs.append("joined \(plural(merged, "back-to-back assistant message")) into one turn")
        }

        let before = messages.count
        messages.removeAll { $0.isEmptyAssistantTurn }
        if messages.count < before {
            repairs.append("dropped \(plural(before - messages.count, "empty assistant message"))")
        }

        let pairing = repairToolPairing(messages)
        messages = pairing.messages
        repairs += pairing.repairs

        var out = request
        out.messages = messages
        return Outcome(request: out, repairs: repairs)
    }

    // MARK: - Steps

    /// An answer whose text opens with `<think>` carries its reasoning inline.
    static func extractInlineReasoning(_ messages: inout [CanonicalMessage]) -> Int {
        var count = 0
        for i in messages.indices where messages[i].role == .assistant {
            let text = messages[i].joinedText
            guard text.drop(while: { $0.isWhitespace }).hasPrefix(ReasoningMarkup.openTag) else { continue }
            let (reasoning, answer) = ReasoningMarkup.split(text)
            let media = messages[i].content.filter { $0.textValue == nil }
            messages[i].content = (answer.isEmpty ? [] : [.text(answer)]) + media
            if let reasoning, messages[i].reasoning?.isEmpty ?? true {
                messages[i].reasoning = reasoning
            }
            count += 1
        }
        return count
    }

    /// One model response is one assistant turn. Two in a row — text and tool
    /// calls sent as separate items, or reasoning in its own item — render as
    /// two turns in a chat template and as a structure error on strict APIs.
    static func mergeConsecutiveAssistants(_ messages: inout [CanonicalMessage]) -> Int {
        var out: [CanonicalMessage] = []
        var merges = 0
        for message in messages {
            guard message.role == .assistant, var last = out.last, last.role == .assistant,
                  last.toolCalls.isEmpty || message.content.isEmpty && message.reasoning == nil else {
                out.append(message)
                continue
            }
            last.content = joinContent(last.content, message.content)
            last.toolCalls += message.toolCalls
            last.reasoning = joinText(last.reasoning, message.reasoning)
            last.reasoningArtifacts += message.reasoningArtifacts
            if last.origin == nil { last.origin = message.origin }
            out[out.count - 1] = last
            merges += 1
        }
        messages = out
        return merges
    }

    /// Every tool call answered, every result right after its call.
    static func repairToolPairing(_ messages: [CanonicalMessage]) -> (messages: [CanonicalMessage], repairs: [String]) {
        var out: [CanonicalMessage] = []
        var names: [String: String] = [:]
        var open: [String] = []
        var held: [CanonicalMessage] = []
        var byPosition = 0, orphans = 0, synthesized = 0, reordered = 0

        func answerRemainingCalls() {
            for id in open {
                out.append(CanonicalMessage(role: .tool, content: [.text(missingResultText)],
                                            name: names[id], toolCallID: id))
                synthesized += 1
            }
            open.removeAll()
        }

        for message in messages {
            switch message.role {
            case .tool:
                var result = message
                var id = result.toolCallID ?? ""
                if !open.contains(id), id.isEmpty || names[id] == nil, let next = open.first {
                    // A client that lost the id still sends results in call order.
                    id = next
                    result.toolCallID = next
                    byPosition += 1
                }
                if let index = open.firstIndex(of: id) {
                    open.remove(at: index)
                    if result.name == nil { result.name = names[id] }
                    out.append(result)
                    if open.isEmpty, !held.isEmpty {
                        reordered += held.count
                        out += held
                        held.removeAll()
                    }
                } else {
                    // Nothing is waiting for this result. Keep what it says, as
                    // something the user reported rather than a dangling reply.
                    let label = result.name ?? names[id] ?? "a tool"
                    let note = CanonicalMessage(
                        role: .user,
                        content: [.text("Result from an earlier call to \(label):\n\(result.joinedText)")]
                            + result.content.filter(\.isImage))
                    if open.isEmpty { out.append(note) } else { held.append(note) }
                    orphans += 1
                }
            case .assistant:
                if !open.isEmpty { answerRemainingCalls() }
                if !held.isEmpty { out += held; held.removeAll() }
                out.append(message)
                for call in message.toolCalls { names[call.id] = call.name }
                open = message.toolCalls.map(\.id)
            default:
                if open.isEmpty { out.append(message) } else { held.append(message) }
            }
        }
        if !held.isEmpty {
            // The conversation moved on without the results. A call left
            // unanswered at the very end is the client's to answer, so only
            // calls someone spoke after are closed.
            answerRemainingCalls()
            out += held
        }

        var repairs: [String] = []
        if byPosition > 0 { repairs.append("matched \(plural(byPosition, "tool result")) to its call by position") }
        if orphans > 0 { repairs.append("kept \(plural(orphans, "tool result")) with no matching call as user messages") }
        if synthesized > 0 { repairs.append("recorded that \(plural(synthesized, "tool call")) never returned a result") }
        if reordered > 0 { repairs.append("moved tool results ahead of \(plural(reordered, "message")) that interrupted them") }
        return (out, repairs)
    }

    // MARK: - Helpers

    static func joinContent(_ a: [CanonicalContent], _ b: [CanonicalContent]) -> [CanonicalContent] {
        guard case .text(let left)? = a.last, case .text(let right)? = b.first else { return a + b }
        if left.isEmpty { return Array(a.dropLast()) + b }
        if right.isEmpty { return a + Array(b.dropFirst()) }
        return Array(a.dropLast()) + [.text(left + "\n\n" + right)] + Array(b.dropFirst())
    }

    static func joinText(_ a: String?, _ b: String?) -> String? {
        switch (a?.isEmpty == false ? a : nil, b?.isEmpty == false ? b : nil) {
        case (let x?, let y?): return x + "\n\n" + y
        case (let x?, nil): return x
        case (nil, let y?): return y
        default: return nil
        }
    }
}

func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
