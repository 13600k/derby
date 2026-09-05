import Foundation
@testable import DerbyCore

/// Context compaction: what happens when a conversation is larger than the
/// model that has to answer it.
///
/// The behaviour under test is deliberately conservative. Compaction is off by
/// default, it never silently drops a message, and it refuses rather than
/// truncating the question it was asked.
func registerCompactionTests() {
    suite("Compaction") {

        // MARK: - Deciding whether to compact

        test("a conversation that fits is left alone") {
            let req = conversation(turns: 4, charsPerTurn: 100)
            try expect(!ContextCompactor.needsCompaction(req, inputLimit: 200_000, outputReserve: 1024))
        }

        test("a model with no known context window is never compacted for") {
            let req = conversation(turns: 400, charsPerTurn: 4_000)
            try expect(!ContextCompactor.needsCompaction(req, inputLimit: 0, outputReserve: 1024),
                       "an unknown window must not trigger lossy shortening")
        }

        test("the output reserve counts against the window") {
            // A window sized exactly to the prompt fits it — until room has to
            // be left for the answer.
            let req = conversation(turns: 5, charsPerTurn: 2_000)
            let window = req.estimatedPromptTokens + 100
            try expect(!ContextCompactor.needsCompaction(req, inputLimit: window, outputReserve: 0))
            try expect(ContextCompactor.needsCompaction(req, inputLimit: window, outputReserve: 500))
        }

        // MARK: - Dropping

        test("drop_oldest keeps the system prompt and the most recent turns") {
            var req = conversation(turns: 40, charsPerTurn: 2_000)
            req.messages.insert(.system("You are a careful assistant."), at: 0)
            let original = req.estimatedPromptTokens

            let out = try await ContextCompactor.compact(
                req, inputLimit: 8_000, outputReserve: 1_000,
                policy: CompactionPolicy(enabled: true, strategy: .dropOldest, keepRecentMessages: 6),
                targetLabel: "Ollama · qwen")

            try expectEqual(out.request.messages.first?.role, .system,
                            "the system prompt is pinned")
            try expectContains(out.request.messages.first?.joinedText ?? "", "careful assistant")
            try expect(out.request.estimatedPromptTokens < original)
            try expect(out.request.estimatedPromptTokens + 1_000 <= 8_000,
                       "compaction must actually fit the window")
            // The last thing the user said always survives.
            try expectEqual(out.request.messages.last?.joinedText, req.messages.last?.joinedText)
            try expect(out.record.droppedMessages > 0)
            try expectEqual(out.record.strategy, .dropOldest)
            try expectNil(out.record.summarizedBy)
        }

        test("the cut always lands on a user message so tool pairs survive") {
            var messages: [CanonicalMessage] = [.system("sys")]
            for i in 0..<30 {
                messages.append(.user(String(repeating: "q\(i) ", count: 500)))
                messages.append(CanonicalMessage(role: .assistant, content: [],
                                                 toolCalls: [CanonicalToolCall(id: "call_\(i)", name: "search",
                                                                               argumentsJSON: "{\"q\":\"\(i)\"}")]))
                messages.append(CanonicalMessage(role: .tool, content: [.text(String(repeating: "r\(i) ", count: 500))],
                                                 toolCallID: "call_\(i)"))
                messages.append(.assistant(String(repeating: "a\(i) ", count: 200)))
            }
            messages.append(.user("and finally?"))
            var req = CanonicalRequest(requestedModel: "smart", messages: messages)
            req.maxOutputTokens = 512

            let out = try await ContextCompactor.compact(
                req, inputLimit: 12_000, outputReserve: 512,
                policy: CompactionPolicy(enabled: true, strategy: .dropOldest, keepRecentMessages: 8),
                targetLabel: "local")

            let history = out.request.messages.filter { $0.role != .system }
            try expectEqual(history.first?.role, .user,
                            "a slice starting on a tool result would be rejected by every provider")

            // No tool result may reference a call that was dropped.
            var seenCalls = Set<String>()
            for m in out.request.messages {
                for c in m.toolCalls { seenCalls.insert(c.id) }
                if let id = m.toolCallID {
                    try expect(seenCalls.contains(id), "orphaned tool result \(id)")
                }
            }
            // ...and no tool call may be left without its result.
            var seenResults = Set<String>()
            for m in out.request.messages { if let id = m.toolCallID { seenResults.insert(id) } }
            for m in out.request.messages {
                for c in m.toolCalls {
                    try expect(seenResults.contains(c.id), "tool call \(c.id) lost its result")
                }
            }
        }

        test("a final message too large for the window fails instead of being truncated") {
            let huge = String(repeating: "x", count: 400_000)   // ~100k tokens
            let req = CanonicalRequest(requestedModel: "smart",
                                       messages: [.system("sys"), .user(huge)])
            try await expectFailure(.contextOverflow) {
                _ = try await ContextCompactor.compact(
                    req, inputLimit: 8_000, outputReserve: 1_000,
                    policy: CompactionPolicy(enabled: true, strategy: .dropOldest),
                    targetLabel: "small model")
            }
        }

        // MARK: - Summarizing

        test("summarize replaces the dropped turns with a summary from the compactor") {
            var req = conversation(turns: 40, charsPerTurn: 2_000)
            req.messages.insert(.system("sys"), at: 0)

            let out = try await ContextCompactor.compact(
                req, inputLimit: 8_000, outputReserve: 1_000,
                policy: CompactionPolicy(enabled: true, strategy: .summarize, keepRecentMessages: 4),
                targetLabel: "Ollama · qwen",
                summarizerName: "Groq · llama",
                summarize: { _ in "The user asked about invoices; the balance was 412 dollars." })

            let summaries = out.request.messages.filter { $0.joinedText.contains("412 dollars") }
            try expectEqual(summaries.count, 1, "exactly one summary is inserted")
            try expectEqual(summaries.first?.role, .system)
            try expectContains(summaries.first?.joinedText ?? "", "summarized")
            try expectEqual(out.record.summarizedBy, "Groq · llama")
            try expectNil(out.record.summaryFailure)
            try expect(out.request.estimatedPromptTokens + 1_000 <= 8_000)
        }

        test("a failing summarizer degrades to dropping, and says so") {
            var req = conversation(turns: 40, charsPerTurn: 2_000)
            req.messages.insert(.system("sys"), at: 0)

            let out = try await ContextCompactor.compact(
                req, inputLimit: 8_000, outputReserve: 1_000,
                policy: CompactionPolicy(enabled: true, strategy: .summarize, keepRecentMessages: 4),
                targetLabel: "local",
                summarizerName: "Groq · llama",
                summarize: { _ in throw DerbyError(kind: .providerDown, message: "connection refused") })

            try expectNil(out.record.summarizedBy)
            try expectContains(out.record.summaryFailure ?? "", "connection refused")
            try expect(out.request.estimatedPromptTokens + 1_000 <= 8_000,
                       "the request still has to fit even when summarizing failed")
            try expectContains(out.record.summary, "connection refused")
        }

        test("summarize with no compactor configured still fits, and reports why") {
            var req = conversation(turns: 40, charsPerTurn: 2_000)
            req.messages.insert(.system("sys"), at: 0)
            let out = try await ContextCompactor.compact(
                req, inputLimit: 8_000, outputReserve: 1_000,
                policy: CompactionPolicy(enabled: true, strategy: .summarize),
                targetLabel: "local")
            try expectContains(out.record.summaryFailure ?? "", "no compaction model")
        }

        test("the transcript handed to the summarizer is bounded by its own window") {
            let dropped = (0..<200).map { CanonicalMessage.user(String(repeating: "z", count: 4_000) + " \($0)") }
            let req = ContextCompactor.summarizationRequest(for: dropped, model: "llama",
                                                            transcriptTokenBudget: 4_000)
            try expect(req.estimatedPromptTokens < 6_000,
                       "summarizing must not overflow the summarizer")
            try expectContains(req.messages.last?.joinedText ?? "", "omitted")
            // The turns nearest the live conversation are the ones kept.
            try expectContains(req.messages.last?.joinedText ?? "", " 199")
        }

        // MARK: - Routing

        test("a too-small target is excluded when compaction is off") {
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 32_000)])
            let config = Fixture.config(accounts: [small],
                                        logicalModels: [Fixture.logical("smart", accounts: [small])])
            try await expectFailure(.contextOverflow) {
                _ = try Router().route(RoutingRequest(logicalModelName: "smart",
                                                      requirements: CapabilityRequirements(required: [.text],
                                                                                           minContextTokens: 600_000),
                                                      promptTokens: 600_000),
                                       snapshot: Fixture.snapshot(config))
            }
        }

        test("the same target is kept, and marked, when compaction is on") {
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 32_000)])
            var lm = Fixture.logical("smart", accounts: [small])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .dropOldest)
            let config = Fixture.config(accounts: [small], logicalModels: [lm])

            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: CapabilityRequirements(required: [.text], minContextTokens: 600_000),
                               promptTokens: 600_000),
                snapshot: Fixture.snapshot(config))

            try expectEqual(decision.plan.attempts.count, 1)
            try expect(decision.plan.compaction.enabled)
            try expectContains(decision.evaluations.first?.note ?? "", "shortened")
        }

        test("a missing capability is still fatal, compaction or not") {
            // Compaction can shrink a conversation; it cannot give a model eyes.
            let textOnly = Fixture.account("Local", models: [Fixture.model("qwen", caps: [.text, .streaming],
                                                                           context: 32_000)])
            var lm = Fixture.logical("smart", accounts: [textOnly])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .dropOldest)
            let config = Fixture.config(accounts: [textOnly], logicalModels: [lm])
            try await expectFailure(.capabilityMismatch) {
                _ = try Router().route(
                    RoutingRequest(logicalModelName: "smart",
                                   requirements: CapabilityRequirements(required: [.text, .vision],
                                                                        minContextTokens: 600_000),
                                   promptTokens: 600_000),
                    snapshot: Fixture.snapshot(config))
            }
        }

        test("the compactor named by the policy is resolved into the plan") {
            let big = Fixture.account("Cloud", models: [Fixture.model("gpt", context: 400_000)])
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 32_000)])
            var lm = Fixture.logical("smart", accounts: [small])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .summarize,
                                             compactor: CompactorSelection(providerID: big.id,
                                                                           modelUUID: big.models[0].id))
            // The compactor lives in another logical model; it still resolves.
            let helper = Fixture.logical("helper", accounts: [big])
            let config = Fixture.config(accounts: [small, big], logicalModels: [lm, helper])

            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: CapabilityRequirements(required: [.text], minContextTokens: 600_000),
                               promptTokens: 600_000),
                snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.compactor?.modelID, "gpt")
        }

        // MARK: - Persistence

        test("a config written before compaction existed still decodes") {
            // The exact shape that once destroyed every provider: a new
            // non-optional field on a persisted type. `compaction` is optional
            // for this reason, and this test is the guard. Simulate an older
            // file by encoding a model and removing the key entirely.
            var lm = Fixture.logical("smart", accounts: [])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .summarize)
            let encoded = try JSONEncoder().encode(lm)
            var object = try expectNotNil(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            try expectNotNil(object["compaction"], "the field is written when set")
            object.removeValue(forKey: "compaction")
            let older = try JSONSerialization.data(withJSONObject: object)

            let back = try JSONDecoder().decode(LogicalModel.self, from: older)
            try expectEqual(back.name, "smart")
            try expectNil(back.compaction, "an absent policy stays absent rather than failing the decode")
            try expect(!(back.compaction ?? .disabled).enabled, "and the default is off")
        }

        test("a compaction policy round-trips through the config file") {
            var lm = Fixture.logical("smart", accounts: [])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .summarize,
                                             compactor: CompactorSelection(providerID: UUID(), modelUUID: UUID()),
                                             keepRecentMessages: 9, targetUtilization: 0.6)
            let data = try JSONEncoder().encode(lm)
            let back = try JSONDecoder().decode(LogicalModel.self, from: data)
            try expectEqual(back.compaction, lm.compaction)
        }

        // MARK: - End to end through the executor

        test("the executor compacts before dispatch and reports it to the client") {
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 24_000)])
            var lm = Fixture.logical("smart", accounts: [small])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .dropOldest, keepRecentMessages: 4)
            let config = Fixture.config(accounts: [small], logicalModels: [lm])

            var request = conversation(turns: 60, charsPerTurn: 3_000)
            request.messages.insert(.system("sys"), at: 0)
            request.requestedModel = "smart"
            let sent = request.messages.count

            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: request.capabilityRequirements,
                               promptTokens: request.estimatedPromptTokens),
                snapshot: Fixture.snapshot(config))

            let adapter = MockAdapter()
            adapter.defaultBehaviour = .succeed(text: "done")
            let sink = RecordingSink()
            let health = HealthRegistry(settings: config.health)
            let executor = Fixture.executor(adapter: adapter, health: health, sink: sink)

            let outcome = try await executor.execute(request, decision: decision, meta: RequestMeta())

            let received = try expectNotNil(adapter.lastRequest("qwen"))
            try expect(received.messages.count < sent, "the provider saw a shortened conversation")
            try expect(received.estimatedPromptTokens <= 24_000)
            try expectEqual(received.messages.last?.joinedText, request.messages.last?.joinedText)

            let record = try expectNotNil(outcome.record.compaction)
            try expectEqual(record.targetLabel, "Local · qwen")
            try expect(record.droppedMessages > 0)
            try expectContains(outcome.record.routingExplanation, "did not see the full conversation")

            // ...and the client is told, in the body.
            let json = OpenAIResponseWriter.derbyMetadata(outcome.record).compactJSONString
            try expectContains(json, "\"compaction\"")
            try expectContains(json, "\"applied\":true")
            _ = sink
        }

        test("compaction is off by default, so a too-small target is still skipped") {
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 24_000)])
            let big = Fixture.account("Cloud", models: [Fixture.model("gpt", context: 400_000)])
            let config = Fixture.config(accounts: [small, big],
                                        logicalModels: [Fixture.logical("smart", accounts: [small, big])])

            var request = conversation(turns: 60, charsPerTurn: 3_000)
            request.requestedModel = "smart"

            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: request.capabilityRequirements,
                               promptTokens: request.estimatedPromptTokens),
                snapshot: Fixture.snapshot(config))

            try expectEqual(decision.plan.attempts.count, 1, "only the large model survives")
            try expectEqual(decision.plan.attempts.first?.target.modelID, "gpt")
            try expect(decision.exclusions.contains { $0.modelID == "qwen" })

            let adapter = MockAdapter()
            let health = HealthRegistry(settings: config.health)
            let executor = Fixture.executor(adapter: adapter, health: health)
            let outcome = try await executor.execute(request, decision: decision, meta: RequestMeta())
            try expectNil(outcome.record.compaction, "an untouched conversation reports no compaction")
            let received = try expectNotNil(adapter.lastRequest("gpt"))
            try expectEqual(received.messages.count, request.messages.count)
        }

        test("summarization runs through the configured provider and reaches the answering model") {
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 24_000)])
            let helperAccount = Fixture.account("Cloud", models: [Fixture.model("summarizer", context: 400_000)])
            var lm = Fixture.logical("smart", accounts: [small])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .summarize,
                                             compactor: CompactorSelection(providerID: helperAccount.id,
                                                                           modelUUID: helperAccount.models[0].id),
                                             keepRecentMessages: 4)
            let config = Fixture.config(accounts: [small, helperAccount],
                                        logicalModels: [lm, Fixture.logical("helper", accounts: [helperAccount])])

            var request = conversation(turns: 60, charsPerTurn: 3_000)
            request.messages.insert(.system("sys"), at: 0)
            request.requestedModel = "smart"

            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: request.capabilityRequirements,
                               promptTokens: request.estimatedPromptTokens),
                snapshot: Fixture.snapshot(config))

            let adapter = MockAdapter()
            adapter.set("summarizer", .succeed(text: "PRIOR CONTEXT: the invoice totalled 412 dollars."))
            adapter.set("qwen", .succeed(text: "done"))
            let health = HealthRegistry(settings: config.health)
            let executor = Fixture.executor(adapter: adapter, health: health)

            let outcome = try await executor.execute(request, decision: decision, meta: RequestMeta())

            let summarizerCall = try expectNotNil(adapter.lastRequest("summarizer"))
            try expectContains(summarizerCall.messages.first?.joinedText ?? "", "compress conversation history")

            let answered = try expectNotNil(adapter.lastRequest("qwen"))
            try expect(answered.messages.contains { $0.joinedText.contains("412 dollars") },
                       "the summary must reach the model that answers")
            try expectEqual(outcome.record.compaction?.summarizedBy, "Cloud · summarizer")
        }

        test("streaming compacts before the first byte and records it") {
            let small = Fixture.account("Local", models: [Fixture.model("qwen", context: 24_000)])
            var lm = Fixture.logical("smart", accounts: [small])
            lm.compaction = CompactionPolicy(enabled: true, strategy: .dropOldest, keepRecentMessages: 4)
            let config = Fixture.config(accounts: [small], logicalModels: [lm])

            var request = conversation(turns: 60, charsPerTurn: 3_000)
            request.requestedModel = "smart"
            request.stream = true

            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: request.capabilityRequirements,
                               promptTokens: request.estimatedPromptTokens, isStreaming: true),
                snapshot: Fixture.snapshot(config))

            let adapter = MockAdapter()
            adapter.defaultBehaviour = .succeed(text: "hello there")
            let health = HealthRegistry(settings: config.health)
            let executor = Fixture.executor(adapter: adapter, health: health)

            var finished: RequestRecord?
            for try await event in executor.stream(request, decision: decision, meta: RequestMeta()) {
                if case .finished(let r) = event { finished = r }
            }
            let record = try expectNotNil(finished)
            try expectNotNil(record.compaction)
            let received = try expectNotNil(adapter.lastRequest("qwen"))
            try expect(received.estimatedPromptTokens <= 24_000)
        }
    }
}

// MARK: - Helpers

/// A synthetic conversation of alternating user/assistant turns.
private func conversation(turns: Int, charsPerTurn: Int) -> CanonicalRequest {
    var messages: [CanonicalMessage] = []
    for i in 0..<turns {
        messages.append(.user(String(repeating: "u", count: charsPerTurn) + " #\(i)"))
        messages.append(.assistant(String(repeating: "a", count: charsPerTurn) + " #\(i)"))
    }
    messages.append(.user("What did we decide?"))
    return CanonicalRequest(requestedModel: "smart", messages: messages)
}
