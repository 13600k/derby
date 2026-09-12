import Foundation

/// Separates reasoning a model wrote inline, as `<think>…</think>`, from its
/// answer.
///
/// Servers with a reasoning parser (Ollama, vLLM, recent llama.cpp) already
/// return the two apart. Without one, a Qwen3 or DeepSeek-R1 answer arrives
/// with its chain of thought in `content` — and a client stores it that way, so
/// the next model in the conversation reads another model's raw thinking as if
/// it were something the assistant said. Splitting at the boundary keeps the
/// answer an answer regardless of which server produced it.
public enum ReasoningMarkup {
    public static let openTag = "<think>"
    public static let closeTag = "</think>"

    /// Splits a complete text.
    ///
    /// - Parameter prefilled: the model's template opens `<think>` itself, so
    ///   everything before a lone `</think>` is reasoning. Only ever set from
    ///   lineage traits: for any other model, text mentioning `</think>` is text.
    public static func split(_ text: String, prefilled: Bool = false) -> (reasoning: String?, content: String) {
        let body = text.drop { $0.isWhitespace }
        if body.hasPrefix(openTag) {
            let afterOpen = body.dropFirst(openTag.count)
            guard let close = afterOpen.range(of: closeTag) else {
                // Stopped mid-thought: there is no answer yet.
                return (nonEmpty(String(afterOpen)), "")
            }
            return (nonEmpty(String(afterOpen[..<close.lowerBound])),
                    dropLeadingNewlines(String(afterOpen[close.upperBound...])))
        }
        if prefilled, let close = text.range(of: closeTag) {
            return (nonEmpty(String(text[..<close.lowerBound])),
                    dropLeadingNewlines(String(text[close.upperBound...])))
        }
        return (nil, text)
    }

    /// The text a fingerprint should cover: the answer without inline reasoning,
    /// trimmed, so the same turn matches whether or not a client kept the tags.
    public static func answerText(_ text: String) -> String {
        split(text).content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dropLeadingNewlines(_ s: String) -> String {
        String(s.drop { $0 == "\n" || $0 == "\r" })
    }

    /// The same split applied to a stream, without delaying ordinary answers by
    /// more than the few characters it takes to rule out a leading `<think>`.
    public struct StreamSplitter: Sendable {
        public enum Piece: Sendable, Equatable {
            case reasoning(String)
            case content(String)
        }

        private enum State: Sendable {
            /// Not yet known whether the stream opens with `<think>`.
            case detecting
            /// Inside reasoning; watching for `</think>`.
            case reasoning
            /// Prefilled template: buffering until `</think>` proves the model
            /// was reasoning, or the stream ends and proves it was not.
            case awaitingClose
            /// Plain content from here on.
            case content
        }

        private var state: State
        private var buffer = ""
        private var trimLeadingNewlines = false

        public init(prefilled: Bool = false) {
            state = prefilled ? .awaitingClose : .detecting
        }

        /// The server reported reasoning separately, so content carries none:
        /// release anything held back and stop looking.
        public mutating func serverSeparatesReasoning() -> [Piece] {
            switch state {
            case .detecting, .awaitingClose:
                state = .content
                let held = buffer
                buffer = ""
                return held.isEmpty ? [] : [.content(held)]
            case .reasoning, .content:
                return []
            }
        }

        public mutating func consume(_ delta: String) -> [Piece] {
            guard !delta.isEmpty else { return [] }
            switch state {
            case .content:
                return emitContent(delta)
            case .detecting:
                buffer += delta
                let body = buffer.drop { $0.isWhitespace }
                if body.isEmpty { return [] }
                if body.count < openTag.count, openTag.hasPrefix(body) { return [] }
                if body.hasPrefix(openTag) {
                    state = .reasoning
                    buffer = String(body.dropFirst(openTag.count))
                    trimLeadingNewlines = true
                    return drainReasoning()
                }
                state = .content
                let held = buffer
                buffer = ""
                return [.content(held)]
            case .reasoning:
                buffer += delta
                return drainReasoning()
            case .awaitingClose:
                buffer += delta
                guard let close = buffer.range(of: closeTag) else { return [] }
                let reasoning = String(buffer[..<close.lowerBound])
                let rest = String(buffer[close.upperBound...])
                buffer = ""
                state = .content
                trimLeadingNewlines = true
                var out: [Piece] = []
                let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(.reasoning(trimmed)) }
                out += emitContent(rest)
                return out
            }
        }

        /// Flushes whatever is still held when the stream ends.
        public mutating func finish() -> [Piece] {
            defer { buffer = "" }
            switch state {
            case .detecting, .awaitingClose:
                state = .content
                return buffer.isEmpty ? [] : [.content(buffer)]
            case .reasoning:
                return buffer.isEmpty ? [] : [.reasoning(buffer)]
            case .content:
                return []
            }
        }

        private mutating func drainReasoning() -> [Piece] {
            if trimLeadingNewlines {
                buffer = String(buffer.drop { $0 == "\n" || $0 == "\r" })
                if buffer.isEmpty { return [] }
                trimLeadingNewlines = false
            }
            if let close = buffer.range(of: closeTag) {
                let reasoning = String(buffer[..<close.lowerBound])
                let rest = String(buffer[close.upperBound...])
                buffer = ""
                state = .content
                trimLeadingNewlines = true
                var out: [Piece] = []
                if !reasoning.isEmpty { out.append(.reasoning(reasoning)) }
                out += emitContent(rest)
                return out
            }
            // Hold back a tail that could be the start of `</think>`.
            let held = Self.partialSuffixLength(buffer, of: closeTag)
            let emitCount = buffer.count - held
            guard emitCount > 0 else { return [] }
            let emit = String(buffer.prefix(emitCount))
            buffer = String(buffer.suffix(held))
            return [.reasoning(emit)]
        }

        private mutating func emitContent(_ text: String) -> [Piece] {
            var text = text
            if trimLeadingNewlines {
                text = String(text.drop { $0 == "\n" || $0 == "\r" })
                if text.isEmpty { return [] }
                trimLeadingNewlines = false
            }
            return [.content(text)]
        }

        /// Length of the longest suffix of `text` that is a proper prefix of `tag`.
        static func partialSuffixLength(_ text: String, of tag: String) -> Int {
            let maxLength = min(text.count, tag.count - 1)
            guard maxLength > 0 else { return 0 }
            for length in stride(from: maxLength, through: 1, by: -1)
            where tag.hasPrefix(String(text.suffix(length))) {
                return length
            }
            return 0
        }
    }
}
