import Foundation
@testable import DerbyCore

/// Carrying a conversation between models: what each model receives from the
/// ones that answered before it.
///
/// Two rules are under test throughout. Reasoning reaches a model only when it
/// is the same lineage and can read it — never a different family. Structure
/// always follows the receiving model's rules, so nothing is rejected, or
/// silently lost, for a reason unrelated to what was said.
func registerHandoffTests() {

    // MARK: - Helpers

    func call(_ id: String, _ name: String = "search", _ arguments: String = "{}") -> CanonicalToolCall {
        CanonicalToolCall(id: id, name: name, argumentsJSON: arguments)
    }
    func assistant(_ text: String = "", calls: [CanonicalToolCall] = [], reasoning: String? = nil,
                   artifacts: [ReasoningArtifact] = [], origin: MessageOrigin? = nil) -> CanonicalMessage {
        CanonicalMessage(role: .assistant, content: text.isEmpty ? [] : [.text(text)], toolCalls: calls,
                         reasoning: reasoning, reasoningArtifacts: artifacts, origin: origin)
    }
    func result(_ id: String?, _ text: String, name: String? = nil) -> CanonicalMessage {
        CanonicalMessage(role: .tool, content: [.text(text)], name: name, toolCallID: id)
    }
    func origin(_ model: String, _ kind: ProviderKind = .openai, account: UUID? = nil) -> MessageOrigin {
        MessageOrigin(modelID: model, providerKind: kind.rawValue, accountID: account)
    }
    func ctx(_ kind: ProviderKind, model: String) -> ProviderContext {
        ProviderContext(account: Fixture.account("Account", kind: kind, models: [Fixture.model(model)]),
                        transport: MockTransport(), secrets: InMemorySecretStore(),
                        credentials: CredentialCache())
    }

    // MARK: - Lineage

    suite("Handoff / lineage") {
        test("quantizations and hosts of the same weights are one lineage") {
            let ollama = ModelLineage.parse("qwen3.6:27b-q4_K_M")
            let vllm = ModelLineage.parse("Qwen/Qwen3.6-27B-FP8")
            let plain = ModelLineage.parse("qwen3.6-27b")
            try expectEqual(ollama.identity, vllm.identity)
            try expectEqual(vllm.identity, plain.identity)
            try expectEqual(ollama.affinity(with: vllm), .identical)
            try expectEqual(ollama.quantization, "q4_k_m")
            try expectEqual(vllm.quantization, "fp8")
            try expectEqual(ollama.family, "qwen")
            try expectEqual(ollama.generation, "3.6")
        }

        test("a locally built model keeps its family but not its identity") {
            // `ollama create honcho-qwen3.6:27b -f Modelfile` — the same weights
            // behind someone's own system prompt.
            let tuned = ModelLineage.parse("honcho-qwen3.6:27b")
            let base = ModelLineage.parse("qwen3.6:27b")
            try expectEqual(tuned.family, "qwen")
            try expectEqual(tuned.generation, "3.6")
            try expectEqual(tuned.size, "27b")
            try expectEqual(tuned.variant, "honcho")
            try expectEqual(tuned.affinity(with: base), .sameFamily,
                            "the same template reads its reasoning, but it is not the same model")
            try expect(tuned.identity != base.identity, "so a warm copy of one is never a copy of the other")
            try expectEqual(ModelLineage.parse("my-own-finetune").family, "unknown")
            try expectEqual(ModelLineage.parse("nomic-embed-text").family, "unknown")
        }

        test("size and release grade how closely two models are related") {
            let base = ModelLineage.parse("qwen3.6:27b")
            try expectEqual(base.affinity(with: .parse("qwen3.6:35b")), .sameFamily)
            try expectEqual(base.affinity(with: .parse("qwen3:32b")), .sameVendor)
            try expectEqual(base.affinity(with: .parse("gpt-5.1")), .foreign)
            try expectEqual(base.affinity(with: .parse("my-custom-finetune")), .unknown)
        }

        test("every provider's name for a Claude model resolves to the same weights") {
            let api = ModelLineage.parse("claude-sonnet-4-5-20250929")
            let bedrock = ModelLineage.parse("anthropic.claude-sonnet-4-5-20250929-v1:0")
            let crossRegion = ModelLineage.parse("us.anthropic.claude-sonnet-4-5-20250929-v1:0")
            try expectEqual(api.identity, bedrock.identity)
            try expectEqual(api.identity, crossRegion.identity)
            try expectEqual(api.generation, "4.5")
            try expectEqual(api.tier, "sonnet")
            try expectEqual(api.affinity(with: .parse("claude-opus-4-5")), .sameFamily)
            let legacy = ModelLineage.parse("claude-3-5-sonnet-20241022")
            try expectEqual(legacy.generation, "3.5")
            try expectEqual(legacy.tier, "sonnet")
        }

        test("OpenAI and Google names parse into release and tier") {
            let codex = ModelLineage.parse("gpt-5.1-codex")
            try expectEqual(codex.family, "gpt")
            try expectEqual(codex.generation, "5.1")
            try expectEqual(codex.tier, "codex")
            try expectEqual(ModelLineage.parse("o4-mini").generation, "o4")
            try expectEqual(ModelLineage.parse("gpt-oss:20b").family, "gpt-oss")
            let gemini = ModelLineage.parse("gemini-3-pro-preview")
            try expectEqual(gemini.family, "gemini")
            try expectEqual(gemini.majorVersion, 3)
        }

        test("family traits describe what each template reads back") {
            let qwen = LineageTraits.for(.parse("qwen3.6:27b"))
            try expect(qwen.inlineThinkTags)
            try expectEqual(qwen.reasoningReplay, .activeToolLoop)
            try expectEqual(qwen.thinkingTemplateSwitch, "enable_thinking")
            try expectEqual(LineageTraits.for(.parse("deepseek-r1:32b")).reasoningReplay, .none)
            try expect(LineageTraits.for(.parse("qwen3-235b-a22b-thinking-2507")).thinkTagPrefilled)
            try expect(LineageTraits.for(.parse("mistral-large-latest")).requiresNineCharToolIDs)
            try expect(LineageTraits.for(.parse("gemma-2-9b-it")).foldsSystemIntoFirstUser)
            try expect(!LineageTraits.for(.parse("gemma3:12b")).foldsSystemIntoFirstUser)
        }
    }

    // MARK: - Inline reasoning

    suite("Handoff / inline reasoning") {
        test("inline think tags split from the answer") {
            let split = ReasoningMarkup.split("<think>\nCheck the units.\n</think>\n\nIt is 42 km.")
            try expectEqual(split.reasoning, "Check the units.")
            try expectEqual(split.content, "It is 42 km.")
            try expectNil(ReasoningMarkup.split("No reasoning here").reasoning)
            try expectNil(ReasoningMarkup.split("Explain the </think> tag").reasoning,
                          "a lone closing tag is only reasoning for a prefilled template")
            try expectEqual(ReasoningMarkup.split("Plan.</think>Answer", prefilled: true).content, "Answer")
        }

        test("a stream holds back only what could be a tag") {
            var splitter = ReasoningMarkup.StreamSplitter()
            var pieces: [ReasoningMarkup.StreamSplitter.Piece] = []
            for delta in ["<th", "ink>\nfirst", " step</thi", "nk>\n\nThe answer"] {
                pieces += splitter.consume(delta)
            }
            pieces += splitter.finish()
            let reasoning = pieces.compactMap { if case .reasoning(let r) = $0 { return r } else { return nil } }.joined()
            let content = pieces.compactMap { if case .content(let c) = $0 { return c } else { return nil } }.joined()
            try expectEqual(reasoning, "first step")
            try expectEqual(content, "The answer")
        }

        test("an ordinary answer streams through without waiting") {
            var splitter = ReasoningMarkup.StreamSplitter()
            try expectEqual(splitter.consume("Hello"), [.content("Hello")])
            try expectEqual(splitter.consume(" <think> is a tag"), [.content(" <think> is a tag")])
        }

        test("a prefilled template's closing tag ends the reasoning") {
            var splitter = ReasoningMarkup.StreamSplitter(prefilled: true)
            var pieces = splitter.consume("Weigh both options")
            try expect(pieces.isEmpty, "held until the tag proves it was reasoning")
            pieces += splitter.consume("</think>\n\nOption B.")
            try expectEqual(pieces, [.reasoning("Weigh both options"), .content("Option B.")])
        }

        test("a server that separates reasoning releases anything held back") {
            var splitter = ReasoningMarkup.StreamSplitter(prefilled: true)
            _ = splitter.consume("Answer text")
            try expectEqual(splitter.serverSeparatesReasoning(), [.content("Answer text")])
            try expectEqual(splitter.consume(" continues"), [.content(" continues")])
        }
    }

    // MARK: - Normalization

    suite("Handoff / normalization") {
        test("one Responses turn sent as several items becomes one assistant turn") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","input":[
              {"type":"message","role":"user","content":"hi"},
              {"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Considered it"}],
               "encrypted_content":"enc-1"},
              {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]},
              {"type":"function_call","call_id":"c1","name":"f","arguments":"{}"},
              {"type":"function_call_output","call_id":"c1","output":[{"type":"input_text","text":"done"}]}]}
            """))
            let r = try OpenAIRequestParser.parseResponses(json)
            try expectEqual(r.messages.count, 3)
            let turn = r.messages[1]
            try expectEqual(turn.role, .assistant)
            try expectEqual(turn.joinedText, "Hello")
            try expectEqual(turn.reasoning, "Considered it")
            try expectEqual(turn.toolCalls.first?.id, "c1")
            try expectEqual(turn.reasoningArtifacts.first?.itemID, "rs_1")
            try expectEqual(turn.reasoningArtifacts.first?.payload, "enc-1")
            try expectEqual(r.messages[2].joinedText, "done")
        }

        test("chat clients that keep reasoning have it read back") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","messages":[{"role":"user","content":"q"},
              {"role":"assistant","content":"a","reasoning_content":"why"},{"role":"user","content":"next"}]}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            try expectEqual(r.messages[1].reasoning, "why")
        }

        test("a tool result that lost its id is matched to its call by position") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("go"), assistant(calls: [call("a1"), call("a2")]),
                result(nil, "first"), result("mismatched-id", "second"),
            ])
            let out = ConversationNormalizer.normalize(request)
            try expectEqual(out.request.messages[2].toolCallID, "a1")
            try expectEqual(out.request.messages[3].toolCallID, "a2")
            try expect(out.repairs.contains { $0.contains("by position") })
        }

        test("results interrupted by a user message are moved back behind their call") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("go"), assistant(calls: [call("c1")]), .user("also, hurry"), result("c1", "ok"),
            ])
            let roles = ConversationNormalizer.normalize(request).request.messages.map(\.role)
            try expectEqual(roles, [.user, .assistant, .tool, .user])
        }

        test("a call the conversation moved past is closed with an explicit no-result") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("go"), assistant(calls: [call("c1", "deploy")]), .user("never mind, stop"),
            ])
            let out = ConversationNormalizer.normalize(request)
            let synthesized = try expectNotNil(out.request.messages.first { $0.role == .tool })
            try expectEqual(synthesized.toolCallID, "c1")
            try expectEqual(synthesized.name, "deploy")
            try expectContains(synthesized.joinedText, "No result")
            // A call still awaiting its result at the very end is the client's to answer.
            let pending = CanonicalRequest(requestedModel: "m", messages: [.user("go"), assistant(calls: [call("c2")])])
            try expect(!ConversationNormalizer.normalize(pending).request.messages.contains { $0.role == .tool })
        }

        test("a result with no call becomes a user message instead of an error") {
            let request = CanonicalRequest(requestedModel: "m", messages: [.user("go"), result("ghost", "42", name: "calc")])
            let messages = ConversationNormalizer.normalize(request).request.messages
            try expectEqual(messages.last?.role, .user)
            try expectContains(messages.last?.joinedText ?? "", "calc")
            try expectContains(messages.last?.joinedText ?? "", "42")
        }

        test("inline reasoning left in history moves out of the answer, and results learn their function") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("q"), assistant("<think>Use grep.</think>Searching.", calls: [call("c1", "grep")]),
                result("c1", "3 hits"),
            ])
            let out = ConversationNormalizer.normalize(request).request
            try expectEqual(out.messages[1].joinedText, "Searching.")
            try expectEqual(out.messages[1].reasoning, "Use grep.")
            try expectEqual(out.messages[2].name, "grep", "Gemini names a response by its function, not its id")
        }
    }

    // MARK: - Planning

    suite("Handoff / planning") {
        test("reasoning continues on the same weights at another quantization") {
            var request = CanonicalRequest(requestedModel: "local", messages: [
                .user("find the bug"),
                assistant(calls: [call("c1", "grep")], reasoning: "The trace points at the parser.",
                          origin: origin("Qwen/Qwen3.6-27B-FP8", .vllm)),
                result("c1", "parser.swift:42", name: "grep"),
            ])
            request.tools = [CanonicalTool(name: "grep")]
            let target = HandoffTarget(modelID: "qwen3.6:27b-q4_K_M", providerKind: .ollama, accountID: UUID())
            let out = HandoffPlanner.plan(request, for: target)
            try expectEqual(out.request.messages[1].reasoning, "The trace points at the parser.")
            try expectEqual(out.record.affinity, .identical)
            try expectEqual(out.record.reasoningCarried, 1)
            try expectEqual(out.record.reasoningWithheld, 0)

            let body = try OpenAIAdapter().buildChatBody(
                out.request, model: target.modelID,
                quirks: OpenAIQuirks.forKind(.ollama, account: Fixture.account("Ollama", kind: .ollama, models: [])),
                stream: false)
            try expectEqual(body["messages"]?[1]?["reasoning"]?.stringValue, "The trace points at the parser.",
                            "Ollama reads earlier reasoning from `reasoning`")
        }

        test("reasoning never crosses into another model family") {
            let request = CanonicalRequest(requestedModel: "local", messages: [
                .user("find the bug"),
                assistant(calls: [call("c1", "grep")], reasoning: "Search before editing.", origin: origin("gpt-5.1")),
                result("c1", "parser.swift:42"),
            ])
            let out = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "qwen3.6:27b", providerKind: .ollama,
                                                                      accountID: UUID()))
            try expectNil(out.request.messages[1].reasoning)
            try expectEqual(out.record.affinity, .foreign)
            try expectEqual(out.record.reasoningWithheld, 1)
            try expectEqual(out.record.previousModel, "gpt-5.1")
            try expect(out.record.isNotable)
            try expectContains(out.record.summary, "gpt-5.1")
        }

        test("reasoning from earlier turns is not replayed even to the same model") {
            let same = origin("qwen3.6:27b", .ollama)
            let request = CanonicalRequest(requestedModel: "local", messages: [
                .user("q1"), assistant("a1", reasoning: "old thought", origin: same),
                .user("q2"), assistant(calls: [call("c1")], reasoning: "current thought", origin: same),
                result("c1", "ok"),
            ])
            let out = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "qwen3.6:27b", providerKind: .ollama,
                                                                      accountID: UUID()))
            try expectNil(out.request.messages[1].reasoning, "Qwen's template reads back only the open tool loop")
            try expectEqual(out.request.messages[3].reasoning, "current thought")
            try expectEqual(out.record.reasoningWithheld, 0, "outside the window is not a loss")
            try expect(!out.record.isNotable, "the same model continuing with nothing changed is not news")
        }

        test("Claude's signed thinking returns only to Claude") {
            let signed = ReasoningArtifact(format: .anthropicThinking, payload: "sig-abc", text: "Check the weather tool.")
            let request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("weather in Paris?"),
                assistant(calls: [call("toolu_1", "weather")], artifacts: [signed],
                          origin: origin("claude-sonnet-4-5-20250929", .anthropic)),
                result("toolu_1", "18C"),
            ])
            let toClaude = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "claude-opus-4-5",
                                                                           providerKind: .anthropic, accountID: UUID()))
            try expectEqual(toClaude.request.messages[1].reasoningArtifacts.count, 1)
            try expectEqual(toClaude.record.signedReasoningCarried, 1)

            let body = try AnthropicAdapter(oauth: false).buildBody(toClaude.request, model: "claude-opus-4-5",
                                                                     ctx: ctx(.anthropic, model: "claude-opus-4-5"),
                                                                     stream: false)
            let blocks = try expectNotNil(body["messages"]?[1]?["content"]?.arrayValue)
            try expectEqual(blocks.first?["type"]?.stringValue, "thinking", "signed thinking goes back first")
            try expectEqual(blocks.first?["signature"]?.stringValue, "sig-abc")

            let toCodex = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "gpt-5.1-codex",
                                                                          providerKind: .chatgptSubscription,
                                                                          accountID: UUID()))
            try expect(toCodex.request.messages[1].reasoningArtifacts.isEmpty)
            try expectEqual(toCodex.record.signedReasoningWithheld, 1)
        }

        test("encrypted reasoning returns only to the account that issued it") {
            let account = UUID()
            let encrypted = ReasoningArtifact(format: .openAIEncryptedReasoning, payload: "gAAAA-secret",
                                              itemID: "rs_1", summaries: ["Looked up the order"],
                                              originModel: "gpt-5.1-codex", originAccount: account)
            let request = CanonicalRequest(requestedModel: "coding", messages: [
                .user("where is my order?"),
                assistant(calls: [call("call_1", "orders")], artifacts: [encrypted],
                          origin: origin("gpt-5.1-codex", .chatgptSubscription, account: account)),
                result("call_1", "shipped"),
            ])
            let same = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "gpt-5.1-codex",
                                                                       providerKind: .chatgptSubscription,
                                                                       accountID: account))
            let input = try expectNotNil(ChatGPTCodexAdapter().buildBody(same.request, model: "gpt-5.1-codex")["input"]?.arrayValue)
            let reasoningIndex = try expectNotNil(input.firstIndex { $0["type"]?.stringValue == "reasoning" })
            let callIndex = try expectNotNil(input.firstIndex { $0["type"]?.stringValue == "function_call" })
            try expect(reasoningIndex < callIndex, "the reasoning precedes the call it led to")
            try expectEqual(input[reasoningIndex]["encrypted_content"]?.stringValue, "gAAAA-secret")

            let otherAccount = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "gpt-5.1-codex",
                                                                               providerKind: .chatgptSubscription,
                                                                               accountID: UUID()))
            try expect(otherAccount.request.messages[1].reasoningArtifacts.isEmpty,
                       "another account cannot decrypt it, and would reject the request")
        }

        test("encrypted reasoning from finished turns goes back to the account that issued it") {
            let account = UUID()
            func sealed(_ payload: String) -> ReasoningArtifact {
                ReasoningArtifact(format: .openAIEncryptedReasoning, payload: payload, itemID: "rs_\(payload)",
                                  originModel: "gpt-5.6-sol", originAccount: account)
            }
            let gpt = origin("gpt-5.6-sol", .chatgptSubscription, account: account)
            let request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("q1"), assistant("a1", artifacts: [sealed("turn-1")], origin: gpt),
                .user("q2"), assistant(calls: [call("call_1", "orders")], artifacts: [sealed("turn-2")], origin: gpt),
                result("call_1", "shipped"),
            ])
            let same = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "gpt-5.6-sol",
                                                                       providerKind: .chatgptSubscription,
                                                                       accountID: account))
            try expectEqual(same.request.messages[1].reasoningArtifacts.map(\.payload), ["turn-1"],
                            "the Responses API takes reasoning back from every turn")
            try expectEqual(same.request.messages[3].reasoningArtifacts.map(\.payload), ["turn-2"])
            try expectEqual(same.record.signedReasoningCarried, 2)
            try expect(!same.record.isNotable, "the same model continuing with everything carried is not news")
            let input = try expectNotNil(ChatGPTCodexAdapter().buildBody(same.request, model: "gpt-5.6-sol")["input"]?.arrayValue)
            try expectEqual(input.compactMap { $0["type"]?.stringValue },
                            ["message", "reasoning", "message", "message", "reasoning", "function_call", "function_call_output"])

            let otherAccount = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "gpt-5.6-sol",
                                                                               providerKind: .chatgptSubscription,
                                                                               accountID: UUID()))
            try expect(otherAccount.request.messages.allSatisfy { $0.reasoningArtifacts.isEmpty })
            try expectEqual(otherAccount.record.signedReasoningWithheld, 2)
        }

        test("signed thinking from finished turns still stays behind for Claude") {
            let claude = origin("claude-opus-4-5", .anthropic)
            let request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("q1"),
                assistant("a1", artifacts: [ReasoningArtifact(format: .anthropicThinking, payload: "sig-old")],
                          origin: claude),
                .user("q2"),
            ])
            let out = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "claude-opus-4-5",
                                                                      providerKind: .anthropic, accountID: UUID()))
            try expect(out.request.messages[1].reasoningArtifacts.isEmpty, "Anthropic binds thinking to its turn")
            try expectEqual(out.record.signedReasoningWithheld, 0, "outside the window is not a loss")
        }

        test("Gemini 3 gets the documented stand-in for another model's tool call") {
            let request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("look it up"),
                assistant(calls: [call("call_x", "lookup")], origin: origin("gpt-5.1")),
                result("call_x", #"{"ok":true}"#),
            ])
            let normalized = ConversationNormalizer.normalize(request).request
            let out = HandoffPlanner.plan(normalized, for: HandoffTarget(modelID: "gemini-3-pro-preview",
                                                                         providerKind: .google, accountID: UUID()))
            try expectEqual(out.request.messages[1].reasoningArtifacts.first?.payload,
                            ReasoningArtifact.geminiUnsignedCallSentinel)
            try expect(out.record.adjustments.contains { $0.contains("Gemini 3") })

            let body = GoogleAdapter().buildBody(out.request, model: "gemini-3-pro-preview")
            try expectEqual(body["contents"]?[1]?["parts"]?[0]?["thoughtSignature"]?.stringValue,
                            ReasoningArtifact.geminiUnsignedCallSentinel)
            try expectEqual(body["contents"]?[2]?["parts"]?[0]?["functionResponse"]?["name"]?.stringValue, "lookup")

            let older = HandoffPlanner.plan(normalized, for: HandoffTarget(modelID: "gemini-2.5-flash",
                                                                           providerKind: .google, accountID: UUID()))
            try expect(older.request.messages[1].reasoningArtifacts.isEmpty, "only Gemini 3 validates signatures")
        }

        test("parallel results reach Gemini as one turn") {
            let request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("both"), assistant(calls: [call("a", "one"), call("b", "two")]),
                result("a", "1", name: "one"), result("b", "2", name: "two"),
            ])
            let body = GoogleAdapter().buildBody(request, model: "gemini-2.5-pro")
            try expectEqual(body["contents"]?.arrayValue?.count, 3)
            try expectEqual(body["contents"]?[2]?["parts"]?.arrayValue?.count, 2,
                            "Gemini rejects a call turn answered by a different number of responses")
        }

        test("tool call ids follow the receiving model's format, consistently") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("go"), assistant(calls: [call("call_abc123XYZ_long", "f")]), result("call_abc123XYZ_long", "1"),
            ])
            let mistral = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "mistral-large-latest",
                                                                          providerKind: .mistral, accountID: UUID()))
            let id = try expectNotNil(mistral.request.messages[1].toolCalls.first?.id)
            try expect(id.range(of: "^[A-Za-z0-9]{9}$", options: .regularExpression) != nil, "got \(id)")
            try expectEqual(mistral.request.messages[2].toolCallID, id)
            try expectEqual(mistral.record.toolCallIDsRewritten, 1)
            let again = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "mistral-large-latest",
                                                                        providerKind: .mistral, accountID: UUID()))
            try expectEqual(again.request.messages[1].toolCalls.first?.id, id, "the same history renders the same way")

            let kimiStyle = CanonicalRequest(requestedModel: "m", messages: [
                .user("go"), assistant(calls: [call("functions.get_weather:0", "get_weather")]),
                result("functions.get_weather:0", "sunny"),
            ])
            let claude = HandoffPlanner.plan(kimiStyle, for: HandoffTarget(modelID: "claude-sonnet-4-5",
                                                                           providerKind: .anthropic, accountID: UUID()))
            let claudeID = try expectNotNil(claude.request.messages[1].toolCalls.first?.id)
            try expect(claudeID.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil)
            try expectEqual(claude.request.messages[2].toolCallID, claudeID)
            let untouched = HandoffPlanner.plan(kimiStyle, for: HandoffTarget(modelID: "qwen3.6:27b",
                                                                              providerKind: .ollama, accountID: UUID()))
            try expectEqual(untouched.record.toolCallIDsRewritten, 0)
        }

        test("instructions are placed where each template accepts them") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .system("a"), .user("hi"), .system("b"), .user("more"),
            ])
            let mistral = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "mistral-small-3.2",
                                                                          providerKind: .ollama, accountID: UUID()))
            try expectEqual(mistral.request.messages.map(\.role), [.system, .user])
            try expectEqual(mistral.request.messages[0].joinedText, "a\n\nb")
            try expectEqual(mistral.request.messages[1].joinedText, "hi\n\nmore")

            let gemma = HandoffPlanner.plan(CanonicalRequest(requestedModel: "m", messages: [.system("be brief"), .user("hi")]),
                                            for: HandoffTarget(modelID: "gemma-2-9b-it", providerKind: .ollama,
                                                               accountID: UUID()))
            try expectEqual(gemma.request.messages.map(\.role), [.user])
            try expectEqual(gemma.request.messages[0].joinedText, "be brief\n\nhi")
        }

        test("images a tool returned move into a user message where tool results are text-only") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("screenshot please"), assistant(calls: [call("c1", "screenshot")]),
                CanonicalMessage(role: .tool, content: [.text("captured"), .image(CanonicalImage(base64: "QUJD"))],
                                 toolCallID: "c1"),
            ])
            let local = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "qwen3-vl:8b", providerKind: .ollama,
                                                                        accountID: UUID()))
            try expect(!local.request.messages[2].hasImages)
            try expectEqual(local.request.messages.last?.role, .user)
            try expect(local.request.messages.last?.hasImages == true)
            let claude = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "claude-sonnet-4-5",
                                                                         providerKind: .anthropic, accountID: UUID()))
            try expect(claude.request.messages[2].hasImages, "Anthropic tool results carry images themselves")
        }

        test("developer instructions become system messages for servers that only know system") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                CanonicalMessage(role: .developer, content: [.text("rules")]), .user("hi"),
            ])
            try expectEqual(HandoffPlanner.plan(request, for: HandoffTarget(modelID: "qwen3:8b", providerKind: .ollama,
                                                                            accountID: UUID())).request.messages[0].role,
                            .system)
            try expectEqual(HandoffPlanner.plan(request, for: HandoffTarget(modelID: "gpt-5.1", providerKind: .openai,
                                                                            accountID: UUID())).request.messages[0].role,
                            .developer)
        }

        test("a policy that turns reasoning off withholds it even from the same model") {
            let same = origin("qwen3.6:27b", .ollama)
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("q"), assistant(calls: [call("c1")], reasoning: "thought", origin: same), result("c1", "ok"),
            ])
            let out = HandoffPlanner.plan(request, for: HandoffTarget(modelID: "qwen3.6:27b", providerKind: .ollama,
                                                                      accountID: UUID()),
                                          policy: HandoffPolicy(replayReasoning: false))
            try expectNil(out.request.messages[1].reasoning)
        }
    }

    // MARK: - Ledger

    suite("Handoff / ledger") {
        test("an answer sent back as history is attributed and its reasoning restored") {
            let ledger = HandoffLedger()
            let answer = CanonicalMessage(role: .assistant, content: [.text("4")], reasoning: "Simple arithmetic.",
                                          reasoningArtifacts: [ReasoningArtifact(format: .anthropicThinking, payload: "sig")])
            await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("What is 2+2?")]),
                                response: answer, origin: origin("claude-sonnet-4-5", .anthropic))
            let followUp = CanonicalRequest(requestedModel: "m", messages: [
                .user("What is 2+2?"), .assistant("4"), .user("And doubled?"),
            ])
            let annotated = await ledger.annotate(followUp)
            try expectEqual(annotated.messages[1].origin?.modelID, "claude-sonnet-4-5")
            try expectEqual(annotated.messages[1].reasoning, "Simple arithmetic.")
            try expectEqual(annotated.messages[1].reasoningArtifacts.count, 1)
            try expectEqual(HandoffLedger.conversationLineage(of: annotated)?.family, "claude")
        }

        test("the same words answering a different question are not mistaken for it") {
            let ledger = HandoffLedger()
            await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("Deploy?")]),
                                response: .assistant("Done."), origin: origin("gpt-5.1"))
            let other = CanonicalRequest(requestedModel: "m", messages: [.user("Delete it?"), .assistant("Done."), .user("ok")])
            try expectNil(await ledger.annotate(other).messages[1].origin)
        }

        test("a tool call id finds its turn even when the text around it changed") {
            let ledger = HandoffLedger()
            await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("weather")]),
                                response: assistant("Checking.", calls: [call("toolu_9", "weather")]),
                                origin: origin("claude-haiku-4-5", .anthropic))
            let history = CanonicalRequest(requestedModel: "m", messages: [
                .user("weather please"), assistant(calls: [call("toolu_9", "weather")]), result("toolu_9", "sun"),
            ])
            try expectEqual(await ledger.annotate(history).messages[1].origin?.modelID, "claude-haiku-4-5")
        }

        test("reasoning the client sent itself wins over the ledger") {
            let ledger = HandoffLedger()
            await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("q")]),
                                response: CanonicalMessage(role: .assistant, content: [.text("a")], reasoning: "ledger"),
                                origin: origin("qwen3:8b", .ollama))
            let history = CanonicalRequest(requestedModel: "m", messages: [
                .user("q"), CanonicalMessage(role: .assistant, content: [.text("a")], reasoning: "client"), .user("next"),
            ])
            try expectEqual(await ledger.annotate(history).messages[1].reasoning, "client")
        }

        test("the ledger stays within its bounds") {
            let ledger = HandoffLedger(limits: .init(maxEntries: 3))
            for i in 0..<5 {
                await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("q\(i)")]),
                                    response: .assistant("a\(i)"), origin: origin("gpt-5.1"))
            }
            try expectEqual(await ledger.count, 3)
            let evicted = CanonicalRequest(requestedModel: "m", messages: [.user("q0"), .assistant("a0"), .user("x")])
            try expectNil(await ledger.annotate(evicted).messages[1].origin, "the oldest entries go first")
        }

        test("a conversation still going keeps its reasoning past the age limit") {
            let ledger = HandoffLedger(limits: .init(maxAge: 100))
            let start = Date(timeIntervalSince1970: 1_000_000)
            await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("q")]),
                                response: CanonicalMessage(role: .assistant, content: [.text("a")], reasoning: "thought"),
                                origin: origin("gpt-5.6-sol", .chatgptSubscription), at: start)
            let history = CanonicalRequest(requestedModel: "m", messages: [.user("q"), .assistant("a"), .user("next")])
            try expectEqual(await ledger.annotate(history, now: start.addingTimeInterval(80)).messages[1].reasoning,
                            "thought")
            try expectEqual(await ledger.annotate(history, now: start.addingTimeInterval(160)).messages[1].reasoning,
                            "thought", "each turn that sends it back restarts the clock")
            try expectNil(await ledger.annotate(history, now: start.addingTimeInterval(400)).messages[1].reasoning,
                          "one nobody continues still expires")
        }
    }

    // MARK: - Adapters

    suite("Handoff / adapters") {
        test("OpenAI-compatible servers get earlier reasoning only in fields they read") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("q"), CanonicalMessage(role: .assistant, content: [.text("a")], reasoning: "why"),
            ])
            func body(_ kind: ProviderKind) throws -> JSONValue {
                try OpenAIAdapter().buildChatBody(request, model: "qwen3:8b",
                                                  quirks: OpenAIQuirks.forKind(kind, account: Fixture.account("A", kind: kind, models: [])),
                                                  stream: false)
            }
            try expectEqual(try body(.vllm)["messages"]?[1]?["reasoning_content"]?.stringValue, "why")
            try expectNil(try body(.openai)["messages"]?[1]?["reasoning_content"],
                          "OpenAI rejects fields it does not define")
            try expectNil(try body(.openAICompatible)["messages"]?[1]?["reasoning"])
        }

        test("a hybrid model's thinking switch follows the request on self-hosted servers") {
            var request = CanonicalRequest(requestedModel: "m", messages: [.user("q")])
            request.reasoning = ReasoningControls(effort: .minimal)
            let quirks = OpenAIQuirks.forKind(.vllm, account: Fixture.account("vLLM", kind: .vllm, models: []))
            let off = try OpenAIAdapter().buildChatBody(request, model: "Qwen/Qwen3-32B", quirks: quirks, stream: false)
            try expectEqual(off["chat_template_kwargs"]?["enable_thinking"]?.boolValue, false)
            request.reasoning = ReasoningControls(effort: .high)
            let on = try OpenAIAdapter().buildChatBody(request, model: "Qwen/Qwen3-32B", quirks: quirks, stream: false)
            try expectEqual(on["chat_template_kwargs"]?["enable_thinking"]?.boolValue, true)
        }

        test("Claude 4.6 and later think adaptively; older models keep a budget") {
            var request = CanonicalRequest(requestedModel: "m", messages: [.user("q")])
            request.reasoning = ReasoningControls(effort: .xhigh)
            request.maxOutputTokens = 32_000
            let adapter = AnthropicAdapter(oauth: false)
            let opus5 = try adapter.buildBody(request, model: "claude-opus-5", ctx: ctx(.anthropic, model: "claude-opus-5"),
                                              stream: false)
            try expectEqual(opus5["thinking"]?["type"]?.stringValue, "adaptive")
            try expectEqual(opus5["output_config"]?["effort"]?.stringValue, "xhigh")
            let sonnet46 = try adapter.buildBody(request, model: "claude-sonnet-4-6",
                                                 ctx: ctx(.anthropic, model: "claude-sonnet-4-6"), stream: false)
            try expectEqual(sonnet46["output_config"]?["effort"]?.stringValue, "high", "Sonnet 4.6 has no xhigh")
            let sonnet45 = try adapter.buildBody(request, model: "claude-sonnet-4-5-20250929",
                                                 ctx: ctx(.anthropic, model: "claude-sonnet-4-5"), stream: false)
            try expectEqual(sonnet45["thinking"]?["type"]?.stringValue, "enabled")
            try expectNil(sonnet45["output_config"])
        }

        test("manual thinking stays off when resuming a tool loop it did not start") {
            var request = CanonicalRequest(requestedModel: "m", messages: [
                .user("q"), assistant(calls: [call("toolu_1", "f")]), result("toolu_1", "ok"),
            ])
            request.reasoning = ReasoningControls(effort: .high)
            request.maxOutputTokens = 16_000
            let body = try AnthropicAdapter(oauth: false).buildBody(request, model: "claude-sonnet-4-5",
                                                                     ctx: ctx(.anthropic, model: "claude-sonnet-4-5"),
                                                                     stream: false)
            try expectNil(body["thinking"], "the loop began without a signed thinking block to continue from")
        }

        test("forcing a tool keeps thinking off in both forms, and adaptive models keep their effort") {
            var request = CanonicalRequest(requestedModel: "m", messages: [.user("look it up")])
            request.tools = [CanonicalTool(name: "lookup")]
            request.toolChoice = .required
            request.reasoning = ReasoningControls(effort: .high)
            request.maxOutputTokens = 16_000
            let adapter = AnthropicAdapter(oauth: false)
            let opus5 = try adapter.buildBody(request, model: "claude-opus-5", ctx: ctx(.anthropic, model: "claude-opus-5"),
                                              stream: false)
            try expectNil(opus5["thinking"], "forced tool use cannot be combined with thinking")
            try expectEqual(opus5["output_config"]?["effort"]?.stringValue, "high")
            try expectEqual(opus5["tool_choice"]?["type"]?.stringValue, "any")
            let sonnet45 = try adapter.buildBody(request, model: "claude-sonnet-4-5",
                                                 ctx: ctx(.anthropic, model: "claude-sonnet-4-5"), stream: false)
            try expectNil(sonnet45["thinking"])
        }

        test("Anthropic signatures and redacted thinking are captured from a response") {
            let json = try expectNotNil(JSONValue.parse("""
            {"id":"msg_1","model":"claude-x","stop_reason":"tool_use","content":[
              {"type":"thinking","thinking":"plan","signature":"sig-1"},
              {"type":"redacted_thinking","data":"opaque"},
              {"type":"tool_use","id":"toolu_1","name":"w","input":{}}]}
            """))
            let message = try AnthropicAdapter(oauth: false).parseResponse(json, fallbackModel: "x").message
            try expectEqual(message.reasoningArtifacts.map(\.format), [.anthropicThinking, .anthropicRedactedThinking])
            try expectEqual(message.reasoningArtifacts.first?.payload, "sig-1")
        }

        test("a streamed Anthropic signature becomes an artifact") {
            let transport = MockTransport()
            transport.stubStream("/v1/messages", events: [
                #"{"type":"message_start","message":{"id":"msg_1","model":"claude-x","usage":{"input_tokens":1}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-xyz"}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
            ])
            var account = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-x")])
            account.baseURLOverride = "https://api.anthropic.com/v1"
            account.auth = .apiKey(SecretRef(account: "k"))
            let context = ProviderContext(account: account, transport: transport,
                                          secrets: InMemorySecretStore(["k": "sk-ant"]), credentials: CredentialCache())
            var request = CanonicalRequest(requestedModel: "m", messages: [.user("q")])
            request.stream = true
            var accumulator = StreamAccumulator()
            for try await event in try await AnthropicAdapter(oauth: false).stream(request, model: "claude-x", ctx: context) {
                accumulator.ingest(event)
            }
            let message = accumulator.makeResponse(fallbackModel: "x").message
            try expectEqual(message.reasoningArtifacts.first?.payload, "sig-xyz")
            try expectEqual(message.reasoningArtifacts.first?.text, "plan")
            try expectEqual(message.joinedText, "Hi")
        }

        test("Gemini thought signatures are captured with the call they belong to") {
            let json = try expectNotNil(JSONValue.parse("""
            {"candidates":[{"finishReason":"STOP","content":{"parts":[
              {"functionCall":{"name":"a","args":{}},"thoughtSignature":"g-sig"},
              {"functionCall":{"name":"b","args":{}}}]}}]}
            """))
            let message = try GoogleAdapter().parseResponse(json, fallbackModel: "gemini-3-pro").message
            try expectEqual(message.reasoningArtifacts.count, 1)
            try expectEqual(message.reasoningArtifacts.first?.payload, "g-sig")
        }

        test("Bedrock carries Claude's signature in reasoningContent") {
            let request = CanonicalRequest(requestedModel: "m", messages: [
                .user("q"),
                assistant(calls: [call("tooluse_1", "f")],
                          artifacts: [ReasoningArtifact(format: .anthropicThinking, payload: "br-sig", text: "t")]),
                result("tooluse_1", "ok"),
            ])
            let body = BedrockAdapter().buildBody(request, model: "anthropic.claude-sonnet-4-5-20250929-v1:0")
            let blocks = try expectNotNil(body["messages"]?[1]?["content"]?.arrayValue)
            try expectEqual(blocks.first?["reasoningContent"]?["reasoningText"]?["signature"]?.stringValue, "br-sig")
        }

        test("Codex asks for encrypted reasoning so a later turn can continue from it") {
            let body = ChatGPTCodexAdapter().buildBody(CanonicalRequest(requestedModel: "m", messages: [.user("q")]),
                                                       model: "gpt-5.1-codex")
            try expectEqual(body["include"]?[0]?.stringValue, "reasoning.encrypted_content")
        }

        test("a Responses client receives reasoning items it can send back") {
            let message = CanonicalMessage(role: .assistant, content: [.text("Hello")], reasoning: "Considered it",
                                           reasoningArtifacts: [ReasoningArtifact(format: .openAIEncryptedReasoning,
                                                                                  payload: "enc", itemID: "rs_7")])
            let object = OpenAIResponseWriter.responsesObject(
                CanonicalResponse(id: "r", model: "gpt-5.1", message: message), record: RequestRecord())
            let first = try expectNotNil(object["output"]?[0])
            try expectEqual(first["type"]?.stringValue, "reasoning")
            try expectEqual(first["id"]?.stringValue, "rs_7")
            try expectEqual(first["encrypted_content"]?.stringValue, "enc")
            try expectEqual(object["output"]?[1]?["type"]?.stringValue, "message")
        }
    }

    // MARK: - Through the executor

    suite("Handoff / end to end") {
        func twoTargets(_ first: (String, ProviderKind, String), _ second: (String, ProviderKind, String))
            -> (DerbyConfig, MockAdapter, Executor) {
            let a = Fixture.account(first.0, kind: first.1, models: [Fixture.model(first.2)])
            let b = Fixture.account(second.0, kind: second.1, models: [Fixture.model(second.2)])
            let config = Fixture.config(accounts: [a, b], logicalModels: [Fixture.logical("coding", accounts: [a, b])])
            let adapter = MockAdapter()
            let executor = Fixture.executor(adapter: adapter, health: HealthRegistry(settings: config.health))
            return (config, adapter, executor)
        }

        /// Turn one answers with a tool call; turn two arrives as a Chat
        /// Completions client sends it — no reasoning — after the first target
        /// has become unavailable, so a different one continues the loop.
        func toolLoop(config: DerbyConfig, adapter: MockAdapter, executor: Executor,
                      firstModel: String, secondModel: String) async throws -> (CanonicalRequest, ExecutionOutcome) {
            adapter.set(firstModel, .respond(CanonicalMessage(
                role: .assistant, toolCalls: [CanonicalToolCall(id: "", name: "grep", argumentsJSON: #"{"q":"TODO"}"#)],
                reasoning: "Search before editing.")))
            var turn1 = CanonicalRequest(requestedModel: "coding", messages: [.user("Clean up the TODOs")])
            turn1.tools = [CanonicalTool(name: "grep")]
            let first = try await executor.execute(turn1, decision: try Router().route(RoutingRequest(turn1),
                                                                                       snapshot: Fixture.snapshot(config)),
                                                   meta: RequestMeta())
            let issued = try expectNotNil(first.response.message.toolCalls.first)
            try expect(issued.id.hasPrefix("call_") && issued.id.count > 8,
                       "a provider that assigns no id gets a unique one, not call_0")

            var turn2 = CanonicalRequest(requestedModel: "coding", messages: [
                .user("Clean up the TODOs"),
                CanonicalMessage(role: .assistant, toolCalls: [issued]),
                CanonicalMessage(role: .tool, content: [.text("3 matches")], toolCallID: issued.id),
            ])
            turn2.tools = turn1.tools
            turn2 = await executor.ledger.annotate(turn2)
            try expectEqual(turn2.messages[1].reasoning, "Search before editing.",
                            "the ledger restores what the client's dialect could not carry")
            adapter.set(firstModel, .fail(DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)))
            adapter.set(secondModel, .succeed(text: "Removed them."))
            let second = try await executor.execute(turn2, decision: try Router().route(RoutingRequest(turn2),
                                                                                        snapshot: Fixture.snapshot(config)),
                                                    meta: RequestMeta())
            return (try expectNotNil(adapter.lastRequest(secondModel)), second)
        }

        test("a tool loop moving from GPT to Qwen withholds GPT's reasoning, and says so") {
            let (config, adapter, executor) = twoTargets(("Cloud", .openai, "gpt-5.1"), ("Local", .ollama, "qwen3.6:27b"))
            let (sent, outcome) = try await toolLoop(config: config, adapter: adapter, executor: executor,
                                                     firstModel: "gpt-5.1", secondModel: "qwen3.6:27b")
            try expectNil(sent.messages[1].reasoning, "another family's reasoning is not handed to Qwen")
            try expectEqual(sent.messages[1].toolCalls.first?.name, "grep", "the call itself survives intact")
            let handoff = try expectNotNil(outcome.record.handoff)
            try expectEqual(handoff.previousModel, "gpt-5.1")
            try expectEqual(handoff.affinity, .foreign)
            try expectEqual(handoff.reasoningWithheld, 1)
            try expectContains(outcome.record.routingExplanation, "Handoff")
            let metadata = OpenAIResponseWriter.derbyMetadata(outcome.record).compactJSONString
            try expectContains(metadata, "\"handoff\"")
            try expectContains(metadata, "\"previous_model\":\"gpt-5.1\"")
        }

        test("the same loop moving between quantizations of one model keeps its reasoning") {
            let (config, adapter, executor) = twoTargets(("Box A", .vllm, "Qwen/Qwen3.6-27B-FP8"),
                                                         ("Box B", .ollama, "qwen3.6:27b-q4_K_M"))
            let (sent, outcome) = try await toolLoop(config: config, adapter: adapter, executor: executor,
                                                     firstModel: "Qwen/Qwen3.6-27B-FP8",
                                                     secondModel: "qwen3.6:27b-q4_K_M")
            try expectEqual(sent.messages[1].reasoning, "Search before editing.")
            let handoff = try expectNotNil(outcome.record.handoff)
            try expectEqual(handoff.affinity, .identical)
            try expectEqual(handoff.reasoningCarried, 1)
            try expectEqual(handoff.reasoningWithheld, 0)
        }

        test("inline think tags are split before the client or the ledger sees them") {
            let account = Fixture.account("Local", kind: .llamaCpp, models: [Fixture.model("qwq-32b")])
            let config = Fixture.config(accounts: [account], logicalModels: [Fixture.logical("local", accounts: [account])])
            let adapter = MockAdapter()
            adapter.set("qwq-32b", .succeed(text: "<think>Plan the answer.</think> Hello there"))
            let executor = Fixture.executor(adapter: adapter, health: HealthRegistry(settings: config.health))
            var request = CanonicalRequest(requestedModel: "local", messages: [.user("hi")])

            let plain = try await executor.execute(request, decision: try Fixture.decision(config, model: "local"),
                                                   meta: RequestMeta())
            try expectEqual(plain.response.message.joinedText.trimmingCharacters(in: .whitespaces), "Hello there")
            try expectEqual(plain.response.message.reasoning, "Plan the answer.")

            request.stream = true
            var text = "", reasoning = ""
            for try await event in executor.stream(request, decision: try Fixture.decision(config, model: "local"),
                                                   meta: RequestMeta()) {
                if case .canonical(.textDelta(let t)) = event { text += t }
                if case .canonical(.reasoningDelta(let r)) = event { reasoning += r }
            }
            try expectEqual(text.trimmingCharacters(in: .whitespaces), "Hello there")
            try expectEqual(reasoning.trimmingCharacters(in: .whitespaces), "Plan the answer.")
        }
    }
}
