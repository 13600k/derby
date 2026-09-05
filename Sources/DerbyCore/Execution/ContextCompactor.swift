import Foundation

/// What Derby did to make a conversation fit a smaller target.
///
/// Recorded on every request it applies to, and reported back to the client.
/// Compaction is lossy: the model that answers has not seen everything the
/// client sent. That must never be silent, so this record is surfaced in
/// `x_derby.compaction`, in request history, and in the routing explanation.
public struct CompactionRecord: Codable, Sendable, Hashable {
    public var strategy: CompactionPolicy.Strategy
    /// The target whose context window forced the shortening.
    public var targetLabel: String
    /// The input limit that had to be met, in tokens.
    public var contextLimit: Int
    /// Estimated prompt size before and after.
    public var originalTokens: Int
    public var compactedTokens: Int
    public var droppedMessages: Int
    public var keptMessages: Int
    /// Model that wrote the summary, when one did.
    public var summarizedBy: String?
    /// Set when summarization was configured but could not run, so the older
    /// turns were dropped outright instead.
    public var summaryFailure: String?

    public init(strategy: CompactionPolicy.Strategy, targetLabel: String, contextLimit: Int,
                originalTokens: Int, compactedTokens: Int, droppedMessages: Int,
                keptMessages: Int, summarizedBy: String? = nil, summaryFailure: String? = nil) {
        self.strategy = strategy
        self.targetLabel = targetLabel
        self.contextLimit = contextLimit
        self.originalTokens = originalTokens
        self.compactedTokens = compactedTokens
        self.droppedMessages = droppedMessages
        self.keptMessages = keptMessages
        self.summarizedBy = summarizedBy
        self.summaryFailure = summaryFailure
    }

    /// One line a human can read in the console or the history list.
    public var summary: String {
        var s = "Shortened \(originalTokens.formattedTokens) → \(compactedTokens.formattedTokens) "
        s += "to fit \(targetLabel) (\(contextLimit.formattedTokens))"
        switch strategy {
        case .dropOldest: s += "; dropped \(droppedMessages) older message\(droppedMessages == 1 ? "" : "s")"
        case .summarize:
            if let by = summarizedBy {
                s += "; \(droppedMessages) older message\(droppedMessages == 1 ? "" : "s") summarized by \(by)"
            } else {
                s += "; dropped \(droppedMessages) older message\(droppedMessages == 1 ? "" : "s")"
            }
        }
        if let f = summaryFailure { s += " (summary unavailable: \(f))" }
        return s
    }
}

/// Shortens a conversation so it fits a target that is too small for it.
///
/// This runs only when a logical model opts in. The default is still to skip a
/// target that cannot hold the conversation, because dropping context silently
/// is worse than a clear error. When it is enabled, the rules are:
///
/// - System and developer messages are pinned. They carry the instructions that
///   make the rest coherent, and they are usually small.
/// - The most recent turns are kept verbatim, because that is what the next
///   answer actually depends on.
/// - The cut always lands on a `user` message, so an assistant's `tool_calls`
///   can never be separated from the `tool` results that answer them. Providers
///   reject that shape outright, which would turn a recoverable size problem
///   into a hard 400.
/// - What was cut is either dropped or replaced by a summary written by a model
///   the user picked for the job.
public enum ContextCompactor {

    public struct Outcome: Sendable {
        public var request: CanonicalRequest
        public var record: CompactionRecord
    }

    /// Writes a summary of the dropped turns. Supplied by the executor, which is
    /// the layer allowed to perform I/O.
    public typealias Summarizer = @Sendable ([CanonicalMessage]) async throws -> String

    /// Whether `request` needs shortening for a target with this input limit.
    public static func needsCompaction(_ request: CanonicalRequest,
                                       inputLimit: Int?,
                                       outputReserve: Int) -> Bool {
        guard let inputLimit, inputLimit > 0 else { return false }
        return request.estimatedPromptTokens + outputReserve > inputLimit
    }

    /// Shortens `request` to fit `inputLimit`.
    ///
    /// Throws `.contextOverflow` when no amount of dropping can help — the
    /// pinned instructions plus the final user message already exceed the
    /// window. Failing is right there: answering from a truncated final question
    /// would produce a confidently wrong response.
    public static func compact(_ request: CanonicalRequest,
                               inputLimit: Int,
                               outputReserve: Int,
                               policy: CompactionPolicy,
                               targetLabel: String,
                               summarizerName: String? = nil,
                               summarize: Summarizer? = nil) async throws -> Outcome {
        let originalTokens = request.estimatedPromptTokens
        let utilization = min(max(policy.targetUtilization, 0.1), 1.0)
        // Aim below the ceiling: the estimate is approximate, and a compaction
        // that lands one token over is a failed request, not a near miss.
        let budget = max(Int(Double(inputLimit) * utilization) - outputReserve, 1)

        let overhead = originalTokens - request.messages.reduce(0) { $0 + $1.estimatedTokens }
        let pinnedIndices = request.messages.indices.filter {
            request.messages[$0].role == .system || request.messages[$0].role == .developer
        }
        let pinnedSet = Set(pinnedIndices)
        let history = request.messages.indices.filter { !pinnedSet.contains($0) }
        let pinnedTokens = pinnedIndices.reduce(0) { $0 + request.messages[$1].estimatedTokens }

        guard history.last != nil else {
            throw DerbyError(kind: .contextOverflow,
                             message: "The system prompt alone (\(originalTokens.formattedTokens)) exceeds \(targetLabel)'s \(inputLimit.formattedTokens) context window.")
        }

        // Widest window of recent turns that fits, never fewer than the last
        // message and never more than the whole history.
        let desiredKeep = max(policy.keepRecentMessages, 1)
        var cut = alignedCut(history, in: request.messages,
                             startingAt: max(history.count - desiredKeep, 0))
        var keptTokens = tokens(of: history[cut...], in: request.messages)

        while pinnedTokens + keptTokens + overhead > budget, cut < history.count - 1 {
            cut = alignedCut(history, in: request.messages, startingAt: cut + 1)
            keptTokens = tokens(of: history[cut...], in: request.messages)
        }

        if pinnedTokens + keptTokens + overhead > inputLimit {
            let need = pinnedTokens + keptTokens + overhead
            throw DerbyError(kind: .contextOverflow,
                             message: "Even after compaction the request needs \(need.formattedTokens), which does not fit \(targetLabel)'s \(inputLimit.formattedTokens) context window. The final message is too large to shorten.")
        }

        let droppedIndices = Array(history[..<cut])
        guard !droppedIndices.isEmpty else {
            // Nothing to remove; the caller should not have asked.
            return Outcome(request: request,
                           record: CompactionRecord(strategy: policy.strategy, targetLabel: targetLabel,
                                                    contextLimit: inputLimit, originalTokens: originalTokens,
                                                    compactedTokens: originalTokens, droppedMessages: 0,
                                                    keptMessages: request.messages.count))
        }
        let dropped = droppedIndices.map { request.messages[$0] }

        var summaryMessage: CanonicalMessage?
        var summarizedBy: String?
        var summaryFailure: String?

        if policy.strategy == .summarize, let summarize {
            do {
                let text = try await summarize(dropped)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    summaryMessage = CanonicalMessage(role: .system, content: [.text(summaryHeader + trimmed)])
                    summarizedBy = summarizerName
                }
            } catch let e as DerbyError {
                summaryFailure = e.message
            } catch {
                summaryFailure = error.localizedDescription
            }
        } else if policy.strategy == .summarize {
            summaryFailure = "no compaction model is configured"
        }

        // The summary is itself context. If it does not fit, drop one more turn
        // rather than overflow — a summary that pushes the request over the
        // limit has defeated its own purpose.
        var finalCut = cut
        if let summary = summaryMessage {
            let summaryTokens = summary.estimatedTokens
            var keep = keptTokens
            while pinnedTokens + keep + summaryTokens + overhead > inputLimit, finalCut < history.count - 1 {
                finalCut = alignedCut(history, in: request.messages, startingAt: finalCut + 1)
                keep = tokens(of: history[finalCut...], in: request.messages)
            }
            if pinnedTokens + keep + summaryTokens + overhead > inputLimit {
                summaryMessage = nil
                summarizedBy = nil
                summaryFailure = "the summary did not fit alongside the most recent turns"
                finalCut = cut
            }
        }

        var messages: [CanonicalMessage] = pinnedIndices.map { request.messages[$0] }
        if let summary = summaryMessage { messages.append(summary) }
        messages.append(contentsOf: history[finalCut...].map { request.messages[$0] })

        var compacted = request
        compacted.messages = messages

        let record = CompactionRecord(strategy: policy.strategy,
                                      targetLabel: targetLabel,
                                      contextLimit: inputLimit,
                                      originalTokens: originalTokens,
                                      compactedTokens: compacted.estimatedPromptTokens,
                                      droppedMessages: finalCut,
                                      keptMessages: messages.count,
                                      summarizedBy: summarizedBy,
                                      summaryFailure: summaryFailure)
        return Outcome(request: compacted, record: record)
    }

    /// The instruction given to the model that writes the summary.
    /// - Parameter transcriptTokenBudget: how much of the dropped history the
    ///   summarizer's own context can hold. The transcript is trimmed from the
    ///   front when it does not fit, because the turns nearest the live
    ///   conversation matter most — and because a summarization call that
    ///   overflows its own model turns one context error into two.
    public static func summarizationRequest(for dropped: [CanonicalMessage],
                                            model: String,
                                            maxTokens: Int = 1200,
                                            transcriptTokenBudget: Int? = nil) -> CanonicalRequest {
        var lines = dropped.map { m -> String in
            var line = "\(m.role.rawValue.uppercased()): \(m.joinedText)"
            if m.hasImages { line += " [image]" }
            for call in m.toolCalls { line += "\n  → called \(call.name)(\(call.argumentsJSON.prefix(400)))" }
            return line
        }
        var elided = 0
        if let budget = transcriptTokenBudget, budget > 0 {
            var charBudget = budget * 4
            var kept: [String] = []
            for line in lines.reversed() {
                if charBudget - line.count < 0 { elided += 1; continue }
                charBudget -= line.count
                kept.append(line)
            }
            lines = kept.reversed()
        }
        var transcript = lines.joined(separator: "\n\n")
        if elided > 0 {
            transcript = "[\(elided) earlier message\(elided == 1 ? " was" : "s were") omitted; they did not fit the summarizing model.]\n\n" + transcript
        }

        var req = CanonicalRequest(requestedModel: model, messages: [
            .system("""
            You compress conversation history for another assistant that is about to \
            continue this conversation with a smaller context window. Write a factual \
            summary of the transcript below.

            Preserve: decisions made, facts established, file names, identifiers, \
            numbers, code or configuration the user provided, constraints the user \
            stated, and anything the user asked to be remembered. Preserve open \
            questions and unfinished work.

            Drop: pleasantries, restatements, and your own commentary. Do not answer \
            the conversation, do not offer help, and do not address the user. Write \
            only the summary.
            """),
            .user("Transcript to summarize:\n\n\(transcript)"),
        ])
        req.maxOutputTokens = maxTokens
        req.stream = false
        return req
    }

    private static let summaryHeader = """
        [Earlier conversation, summarized because the model answering has a smaller \
        context window than the conversation required. Treat it as an accurate record \
        of what was said, but not a verbatim one.]

        """

    // MARK: - Internals

    /// Moves a cut point forward until it lands on a `user` message.
    ///
    /// A conversation slice that begins with a `tool` result, or that keeps an
    /// assistant's `tool_calls` whose results were dropped, is rejected by every
    /// provider. Cutting only at user turns makes that impossible by
    /// construction.
    private static func alignedCut(_ history: [Int], in messages: [CanonicalMessage],
                                   startingAt start: Int) -> Int {
        guard start > 0 else { return 0 }
        var i = min(start, history.count - 1)
        while i < history.count, messages[history[i]].role != .user { i += 1 }
        if i >= history.count {
            // No user turn at or after the requested point; fall back to the last
            // one anywhere, and failing that keep everything.
            if let last = history.lastIndex(where: { messages[$0].role == .user }) { return last }
            return 0
        }
        return i
    }

    private static func tokens(of slice: ArraySlice<Int>, in messages: [CanonicalMessage]) -> Int {
        slice.reduce(0) { $0 + messages[$1].estimatedTokens }
    }
}

extension CanonicalMessage {
    /// Cheap per-message estimate, consistent with
    /// `CanonicalRequest.estimatedPromptTokens` so the two can be compared.
    public var estimatedTokens: Int {
        var chars = role.rawValue.count + 4
        var images = 0
        for c in content {
            switch c {
            case .text(let t): chars += t.count
            case .refusal(let t): chars += t.count
            case .image(let img):
                images += 1
                if let b = img.base64 { chars += min(b.count / 40, 4000) }
            case .audio(let a): chars += min(a.base64.count / 40, 4000)
            }
        }
        for tc in toolCalls { chars += tc.name.count + tc.argumentsJSON.count }
        return chars / 4 + images * 800
    }
}
