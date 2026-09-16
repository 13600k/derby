import Foundation
@testable import DerbyCore

func registerModelMetadataTests() {

    suite("Model metadata / discovery") {
        test("Ollama's native endpoint yields context, modalities and hardware facts") {
            // /v1/models reports only an id; /api/tags reports all of this.
            let item = try expectNotNil(JSONValue.parse("""
            {"name":"qwen3.6:27b","model":"qwen3.6:27b","size":17420432493,
             "modified_at":"2026-07-25T18:13:56.795678145-04:00",
             "details":{"family":"qwen35","parameter_size":"27.8B","quantization_level":"Q4_K_M",
                        "format":"gguf","context_length":262144,"embedding_length":5120},
             "capabilities":["vision","completion","tools","thinking"]}
            """))
            let model = try expectNotNil(OllamaDiscovery.parse(item))
            let caps = try expectNotNil(model.capabilities)
            try expectEqual(caps.contextWindow, 262_144)
            try expect(caps.flags.contains(.vision))
            try expect(caps.flags.contains(.tools))
            try expect(caps.flags.contains(.reasoning), "\"thinking\" means reasoning")
            try expect(caps.flags.contains(.text))
            try expectEqual(caps.source, .discovered)

            let profile = try expectNotNil(model.profile)
            try expectEqual(profile.parameterSize, "27.8B")
            try expectEqual(profile.quantization, "Q4_K_M")
            try expectEqual(profile.family, "qwen35")
            try expectEqual(model.pricing?.isFlatRate, true, "local inference has no per-token cost")
        }

        test("an Ollama embedding model is not advertised as a chat model") {
            let item = try expectNotNil(JSONValue.parse("""
            {"model":"nomic-embed-text:latest","size":274302450,
             "details":{"family":"nomic-bert","context_length":8192,"embedding_length":768},
             "capabilities":["embedding"]}
            """))
            let model = try expectNotNil(OllamaDiscovery.parse(item))
            let caps = try expectNotNil(model.capabilities)
            try expect(caps.flags.contains(.embeddings))
            try expect(!caps.flags.contains(.text), "an embedding model cannot answer a chat request")
            try expectEqual(caps.embeddingDimensions, 768)
            try expectEqual(caps.contextWindow, 8192)
        }

        test("the native base URL is derived from the OpenAI-compatible one") {
            try expectEqual(OllamaDiscovery.nativeBase(from: "http://127.0.0.1:11434/v1"), "http://127.0.0.1:11434")
            try expectEqual(OllamaDiscovery.nativeBase(from: "http://host:11434/v1/"), "http://host:11434")
            try expectEqual(OllamaDiscovery.nativeBase(from: "http://host:11434"), "http://host:11434")
        }

        test("an OpenRouter-style listing yields limits, modalities and pricing") {
            let adapter = OpenAIAdapter()
            let item = try expectNotNil(JSONValue.parse("""
            {"id":"vendor/model-x","name":"Model X","description":"a model",
             "context_length":200000,
             "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
             "supported_parameters":["tools","structured_outputs","reasoning","response_format"],
             "top_provider":{"max_completion_tokens":32000},
             "pricing":{"prompt":"0.000003","completion":"0.000015"}}
            """))
            let model = try expectNotNil(adapter.parseListedModel(item, kind: .openrouter))
            let caps = try expectNotNil(model.capabilities)
            try expectEqual(caps.contextWindow, 200_000)
            try expectEqual(caps.maxOutputTokens, 32_000)
            try expect(caps.flags.contains(.vision))
            try expect(caps.flags.contains(.tools))
            try expect(caps.flags.contains(.jsonSchema))
            try expect(caps.flags.contains(.reasoning))
            // Per-token prices are published; Derby works per million.
            try expectClose(try expectNotNil(model.pricing?.inputPerMTok), 3.0, tolerance: 0.0001)
            try expectClose(try expectNotNil(model.pricing?.outputPerMTok), 15.0, tolerance: 0.0001)
        }

        test("llama.cpp's listing and /props state the context window and tool support") {
            let transport = MockTransport()
            transport.stub("/models", json: """
            {"object":"list","data":[{"id":"ornith-1.5-35b-a3b","object":"model","owned_by":"llamacpp",
              "meta":{"n_ctx":262144,"n_ctx_train":262144,"n_params":34660610688}}]}
            """)
            transport.stub("/props", json: """
            {"total_slots":1,"default_generation_settings":{"n_ctx":131072},
             "modalities":{"vision":false,"audio":false},
             "chat_template":"{% if enable_thinking %}<think>{% endif %}",
             "chat_template_caps":{"supports_tools":true,"supports_tool_calls":true,
                                   "supports_parallel_tool_calls":true}}
            """)
            var account = Fixture.account("llama", kind: .llamaCpp, models: [])
            account.baseURLOverride = "http://127.0.0.1:8081/v1"
            let ctx = ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                                      credentials: CredentialCache())
            let models = try await OpenAIAdapter().listModels(ctx)
            let caps = try expectNotNil(models.first?.capabilities)
            try expectEqual(caps.contextWindow, 131_072, "the slot context beats the listing's n_ctx")
            try expect(caps.flags.contains(.tools))
            try expect(caps.flags.contains(.parallelTools))
            try expect(caps.flags.contains(.reasoning))
            try expect(caps.flags.contains(.jsonSchema))
            try expect(!caps.flags.contains(.vision))
            try expectEqual(caps.source, .discovered)

            // Without /props, the listing's own n_ctx still beats the 8K placeholder.
            let listed = try expectNotNil(OpenAIAdapter().parseListedModel(try expectNotNil(JSONValue.parse("""
            {"id":"ornith-1.5-35b-a3b","meta":{"n_ctx":262144}}
            """)), kind: .llamaCpp))
            try expectEqual(listed.capabilities?.contextWindow, 262_144)
        }

        // A self-hosted server states an id and, if you are lucky, a window. What
        // the build supports depends on how it was launched — a vLLM started
        // with a tool parser lists the same model as one started without — so
        // the only source is the server's own answer.
        test("a self-hosted server is asked what it supports, and answers") {
            let transport = MockTransport()
            transport.stub("/models", json: """
            {"object":"list","data":[{"id":"Qwen 3.8","object":"model","owned_by":"vllm",
              "max_model_len":262144,"root":"/models/Qwen3.8-27B-FP8"}]}
            """)
            // This build takes everything except images.
            transport.responder = { request in
                guard request.url.path.hasSuffix("/chat/completions") else { return nil }
                let body = request.body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                let asksForImage = (body?["messages"]?[0]?["content"]?.arrayValue ?? [])
                    .contains { $0["type"]?.stringValue == "image_url" }
                if asksForImage {
                    return OutboundResponse(status: 400, headers: [:],
                                            body: Data(#"{"error":{"message":"multimodal not supported"}}"#.utf8))
                }
                return OutboundResponse(status: 200, headers: [:], body: Data("""
                {"id":"c","choices":[{"index":0,"message":{"role":"assistant","content":null,
                  "reasoning":"We"},"finish_reason":"length"}]}
                """.utf8))
            }

            var account = Fixture.account("enzotide", kind: .vllm, models: [])
            account.baseURLOverride = "http://enzotide:8000/v1"
            let ctx = ProviderContext(account: account, transport: transport,
                                      secrets: InMemorySecretStore(), credentials: CredentialCache())
            let model = try expectNotNil(try await OpenAIAdapter().listModels(ctx).first)
            let caps = try expectNotNil(model.capabilities)

            // vLLM publishes the window under its own name, not OpenAI's.
            try expectEqual(caps.contextWindow, 262_144)
            try expect(caps.flags.contains(.tools))
            try expect(caps.flags.contains(.parallelTools))
            try expect(caps.flags.contains(.jsonSchema))
            // The answer carried a reasoning field, so a parser is running.
            try expect(caps.flags.contains(.reasoning))
            // Refused outright, so not claimed however the name reads.
            try expect(!caps.flags.contains(.vision))
            try expectEqual(caps.source, .discovered)
        }

        test("a server that cannot answer loses nothing it already stated") {
            let transport = MockTransport()
            transport.stub("/models", json: """
            {"object":"list","data":[{"id":"gpt-4o","object":"model","max_model_len":128000}]}
            """)
            // Every probe fails the way an overloaded server fails.
            transport.responder = { request in
                guard request.url.path.hasSuffix("/chat/completions") else { return nil }
                return OutboundResponse(status: 503, headers: [:], body: Data())
            }
            var account = Fixture.account("busy", kind: .vllm, models: [])
            account.baseURLOverride = "http://127.0.0.1:8000/v1"
            let ctx = ProviderContext(account: account, transport: transport,
                                      secrets: InMemorySecretStore(), credentials: CredentialCache())
            let model = try expectNotNil(try await OpenAIAdapter().listModels(ctx).first)
            let caps = try expectNotNil(model.capabilities)
            // A 5xx proves nothing: the catalog's own account of gpt-4o stands.
            try expect(caps.flags.contains(.tools), "a sick server must not strip known capabilities")
            try expectEqual(caps.contextWindow, 128_000)
        }

        test("metered APIs are never probed") {
            let transport = MockTransport()
            transport.stub("/models", json: #"{"data":[{"id":"gpt-4o","object":"model"}]}"#)
            let account = Fixture.account("OpenAI", kind: .openai, models: [])
            let ctx = ProviderContext(account: account, transport: transport,
                                      secrets: InMemorySecretStore(), credentials: CredentialCache())
            _ = try await OpenAIAdapter().listModels(ctx)
            try expect(!transport.requests.contains { $0.url.path.hasSuffix("/chat/completions") },
                       "probing a metered API would bill the user to learn what it already publishes")
        }

        test("a bare listing falls back to the bundled catalog") {
            let adapter = OpenAIAdapter()
            let model = try expectNotNil(
                adapter.parseListedModel(.object(["id": .string("claude-sonnet-4-5")]), kind: .openai))
            let caps = try expectNotNil(model.capabilities)
            try expect(caps.contextWindow != nil, "the catalog should supply what the server omitted")
        }
    }

    suite("Model metadata / merging") {
        test("stated facts win and gaps are filled") {
            let discovered = ModelCapabilities(flags: [.text, .streaming, .tools],
                                               contextWindow: 262_144, source: .discovered)
            let catalog = ModelCapabilities(flags: [.text, .streaming, .jsonMode],
                                            contextWindow: 8_192, maxOutputTokens: 4_096)
            let merged = discovered.fillingGaps(from: catalog)
            try expectEqual(merged.contextWindow, 262_144, "a discovered window must not be overwritten")
            try expectEqual(merged.maxOutputTokens, 4_096, "an unknown must be filled from the catalog")
            try expect(merged.flags.contains(.tools))
            try expect(merged.flags.contains(.jsonMode))
        }

        test("a modality is never inherited when the source stated its own") {
            // Claiming vision a model lacks becomes a hard failure at request time.
            let discovered = ModelCapabilities(flags: [.text, .streaming, .vision], source: .discovered)
            let catalog = ModelCapabilities(flags: [.text, .streaming, .audioInput])
            let merged = discovered.fillingGaps(from: catalog)
            try expect(merged.flags.contains(.vision))
            try expect(!merged.flags.contains(.audioInput), "modalities are asserted, not inherited")
        }

        test("a source that states no modality may inherit one") {
            let discovered = ModelCapabilities(flags: [.text, .streaming, .tools], source: .discovered)
            let catalog = ModelCapabilities(flags: [.text, .streaming, .vision])
            try expect(discovered.fillingGaps(from: catalog).flags.contains(.vision))
        }

        test("unknown facts are named so the user can fill them in") {
            let sparse = ModelCapabilities(flags: [.text], source: .discovered)
            try expectContains(sparse.missingFacts.joined(separator: ","), "context window")
            let complete = ModelCapabilities(flags: [.text], contextWindow: 1000, maxOutputTokens: 100)
            try expect(complete.missingFacts.isEmpty)
        }

        test("an explicit input limit is what a prompt is fitted against") {
            let caps = ModelCapabilities(flags: [.text], contextWindow: 1_048_576,
                                         maxOutputTokens: 8192, maxInputTokens: 32_000)
            try expectEqual(caps.effectiveInputLimit, 32_000)
            let need = CapabilityRequirements(required: [.text], minContextTokens: 40_000)
            try expect(need.unmetReason(for: caps) != nil, "the input limit must bind, not the total window")
        }
    }

    suite("Model metadata / logical model shape") {
        func target(_ name: String, _ flags: CapabilityFlags, context: Int?, maxOut: Int? = nil) -> ProviderAccount {
            Fixture.account(name, models: [
                Fixture.model("m-\(name.lowercased())", caps: flags, context: context)
            ])
        }

        test("a group promises only what every target can do") {
            // vision+text→text alongside text→text: usable together, but the
            // group can only *guarantee* text.
            let visionCapable = target("Vision", [.text, .streaming, .tools, .vision], context: 200_000)
            let textOnly = target("Text", [.text, .streaming, .tools], context: 32_000)
            let config = Fixture.config(accounts: [visionCapable, textOnly],
                                        logicalModels: [Fixture.logical("smart", accounts: [visionCapable, textOnly])])
            let resolved = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "smart"))
            let summary = LogicalModelCapabilitySummary.summarize(resolved)

            try expect(!summary.guaranteed.contains(.vision), "only one target has vision")
            try expect(summary.available.contains(.vision), "but a vision request can still be served")
            try expect(summary.partial.contains(.vision))
            try expect(summary.guaranteed.contains(.tools), "both have tools")
            try expectEqual(summary.guaranteedContextWindow, 32_000, "the floor, not the ceiling")
            try expectEqual(summary.maxContextWindow, 200_000)
            try expectEqual(summary.targetCount, 2)
            try expect(summary.incompatible.isEmpty)
        }

        test("a model that emits images rather than text is reported as incompatible") {
            // The user's rule: a text→image model does not belong in a text group.
            let textModel = target("Text", [.text, .streaming], context: 32_000)
            let imageModel = Fixture.account("Imagen", models: [
                Fixture.model("m-image", caps: [.imageOutput], context: 4_000)
            ])
            let config = Fixture.config(accounts: [textModel, imageModel],
                                        logicalModels: [Fixture.logical("smart", accounts: [textModel, imageModel])])
            let resolved = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "smart"))
            let summary = LogicalModelCapabilitySummary.summarize(resolved)

            try expectEqual(summary.targetCount, 1, "only the text model can serve a chat request")
            try expectEqual(summary.incompatible.count, 1)
            try expectContains(summary.incompatible[0].reason, "image")
            try expectContains(summary.incompatible[0].reason, "not text")
        }

        test("an embedding model in a chat group is called out") {
            let textModel = target("Text", [.text, .streaming], context: 32_000)
            let embedder = Fixture.account("Embed", models: [
                Fixture.model("m-embed", caps: [.embeddings], context: 8_192)
            ])
            let config = Fixture.config(accounts: [textModel, embedder],
                                        logicalModels: [Fixture.logical("smart", accounts: [textModel, embedder])])
            let resolved = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "smart"))
            let summary = LogicalModelCapabilitySummary.summarize(resolved)
            try expectEqual(summary.targetCount, 1)
            try expectContains(summary.incompatible.first?.reason ?? "", "embedding")
        }

        test("an all-embedding group is coherent, not broken") {
            let a = Fixture.account("A", models: [Fixture.model("e1", caps: [.embeddings], context: 8192)])
            let b = Fixture.account("B", models: [Fixture.model("e2", caps: [.embeddings], context: 2048)])
            let config = Fixture.config(accounts: [a, b],
                                        logicalModels: [Fixture.logical("embed", accounts: [a, b])])
            let resolved = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "embed"))
            let summary = LogicalModelCapabilitySummary.summarize(resolved)
            try expectEqual(summary.targetCount, 2)
            try expect(summary.incompatible.isEmpty)
            try expect(summary.guaranteed.contains(.embeddings))
            try expectEqual(summary.guaranteedContextWindow, 2048)
        }

        test("one unknown window means no guaranteed floor is promised") {
            let known = target("Known", [.text, .streaming], context: 32_000)
            let unknown = target("Unknown", [.text, .streaming], context: nil)
            let config = Fixture.config(accounts: [known, unknown],
                                        logicalModels: [Fixture.logical("smart", accounts: [known, unknown])])
            let resolved = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "smart"))
            let summary = LogicalModelCapabilitySummary.summarize(resolved)
            try expectNil(summary.guaranteedContextWindow,
                          "an unknown window could be smaller than any known one")
            try expectEqual(summary.maxContextWindow, 32_000)
        }
    }

    suite("Model metadata / context fitting") {
        test("room is reserved for the answer when the client sends no max_tokens") {
            // A prompt that merely fits is not enough — the model must be able to reply.
            let small = Fixture.account("Small", models: [Fixture.model("s", context: 8_000)])
            let large = Fixture.account("Large", models: [Fixture.model("l", context: 200_000)])
            let config = Fixture.config(accounts: [small, large],
                                        logicalModels: [Fixture.logical("x", accounts: [small, large])])
            let request = RoutingRequest(logicalModelName: "x",
                                         requirements: CapabilityRequirements(required: [.text],
                                                                              minContextTokens: 7_500),
                                         promptTokens: 7_500,
                                         maxOutputTokens: nil)
            let decision = try Router().route(request, snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Large",
                            "8k of context with 7.5k of prompt leaves no room to answer")
        }

        test("an explicit max_tokens is respected as the reserve") {
            let small = Fixture.account("Small", models: [Fixture.model("s", context: 8_000)])
            let config = Fixture.config(accounts: [small],
                                        logicalModels: [Fixture.logical("x", accounts: [small])])
            let request = RoutingRequest(logicalModelName: "x",
                                         requirements: CapabilityRequirements(required: [.text],
                                                                              minContextTokens: 1_200),
                                         promptTokens: 1_000, maxOutputTokens: 200)
            let decision = try Router().route(request, snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1, "1.2k of 8k fits comfortably")
        }
    }
}

func registerContractTests() {

    func mixedGroup(constraints: LogicalModelConstraints? = nil) -> DerbyConfig {
        // A vision-capable 200k model and a text-only 32k model: a legitimate
        // group that guarantees text and offers vision.
        let visionCapable = Fixture.account("Vision", models: [
            Fixture.model("m-vision", caps: [.text, .streaming, .tools, .vision], context: 200_000)])
        let textOnly = Fixture.account("Text", models: [
            Fixture.model("m-text", caps: [.text, .streaming, .tools], context: 32_000)])
        var lm = Fixture.logical("smart", accounts: [visionCapable, textOnly])
        lm.constraints = constraints
        return Fixture.config(accounts: [visionCapable, textOnly], logicalModels: [lm])
    }

    func summarize(_ config: DerbyConfig) throws -> LogicalModelCapabilitySummary {
        let resolved = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "smart"))
        return LogicalModelCapabilitySummary.summarize(resolved)
    }

    suite("Logical model contract") {
        test("with no constraint the group offers what its targets support") {
            let summary = try summarize(mixedGroup())
            try expect(summary.available.contains(.vision))
            try expect(!summary.isNarrowed)
            try expectNil(summary.unconstrained)
        }

        test("unchecking a capability narrows what the group advertises") {
            let constrained = LogicalModelConstraints(
                allowedCapabilities: [.text, .streaming, .tools])
            let summary = try summarize(mixedGroup(constraints: constrained))
            try expect(!summary.available.contains(.vision), "vision was withheld")
            try expect(summary.guaranteed.contains(.tools))
            try expect(summary.isNarrowed)
            try expect(summary.withheld.contains(.vision))
        }

        test("a withheld capability is refused, not quietly routed anyway") {
            // Otherwise /v1/models would be telling clients something untrue.
            let constrained = LogicalModelConstraints(allowedCapabilities: [.text, .streaming, .tools])
            let config = mixedGroup(constraints: constrained)
            var request = CanonicalRequest(requestedModel: "smart")
            request.messages = [CanonicalMessage(role: .user, content: [
                .text("what is this"), .image(CanonicalImage(base64: "AAA", mimeType: "image/png")),
            ])]
            let error = try await expectFailure(.capabilityMismatch) {
                _ = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            }
            try expectContains(error.message, "vision")
            try expectContains(error.message, "smart")
        }

        test("an allowed capability still routes normally") {
            let constrained = LogicalModelConstraints(allowedCapabilities: [.text, .streaming, .tools])
            let config = mixedGroup(constraints: constrained)
            let decision = try Fixture.decision(config, model: "smart")
            try expectEqual(decision.plan.attempts.count, 2)
        }

        test("a context cap is advertised and enforced") {
            let config = mixedGroup(constraints: LogicalModelConstraints(maxContextTokens: 16_000))
            let summary = try summarize(config)
            try expectEqual(summary.maxContextWindow, 16_000, "the cap replaces the 200k ceiling")

            let error = try await expectFailure(.contextOverflow) {
                _ = try Router().route(
                    RoutingRequest(logicalModelName: "smart",
                                   requirements: CapabilityRequirements(required: [.text]),
                                   promptTokens: 20_000),
                    snapshot: Fixture.snapshot(config))
            }
            try expectContains(error.message, "capped")
        }

        test("a prompt within the cap is unaffected") {
            let config = mixedGroup(constraints: LogicalModelConstraints(maxContextTokens: 16_000))
            let decision = try Router().route(
                RoutingRequest(logicalModelName: "smart",
                               requirements: CapabilityRequirements(required: [.text]),
                               promptTokens: 4_000),
                snapshot: Fixture.snapshot(config))
            try expect(!decision.plan.attempts.isEmpty)
        }

        test("a constraint can only narrow, never invent a capability") {
            // Claiming audio no target has would be a promise Derby cannot keep.
            let constrained = LogicalModelConstraints(
                allowedCapabilities: [.text, .streaming, .tools, .vision, .audioInput])
            let summary = try summarize(mixedGroup(constraints: constrained))
            try expect(!summary.available.contains(.audioInput))
            try expect(summary.available.contains(.vision))
        }

        test("the advertised contract reaches clients through /v1/models") {
            let constrained = LogicalModelConstraints(allowedCapabilities: [.text, .streaming, .tools],
                                                      maxContextTokens: 16_000)
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(mixedGroup(constraints: constrained)))
            let entry = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "smart" })
            let caps = (entry["derby"]?["available_capabilities"]?.arrayValue ?? []).compactMap { $0.stringValue }
            try expect(!caps.contains("vision"), "a withheld capability must not be advertised")
            try expectEqual(entry["derby"]?["supports_vision"]?.boolValue, false)
            try expectEqual(entry["context_window"]?.intValue, 16_000)
        }

        test("configurations written before constraints existed still load") {
            let json = """
            {"id":"\(UUID().uuidString)","name":"smart","summary":"","enabled":true,
             "targets":[],"policy":{"strategy":"priority","scoreWeights":{"quality":0.35,
             "latency":0.2,"cost":0.1,"health":0.2,"quota":0.1,"priority":0.05,
             "providerPreference":0,"localPreference":0,"contextHeadroom":0},
             "latencyMetric":"ttft","respectCircuitBreakers":true,"respectQuotas":true,
             "maxCandidates":8,"deterministic":false},
             "retry":{"maxRetriesPerTarget":1,"initialBackoffSeconds":0.25,"backoffMultiplier":2,
             "maxBackoffSeconds":8,"jitter":true,"respectRetryAfter":true},
             "failover":{"enabled":true,"maxAttempts":4,"dispositions":{}},
             "timeouts":{"overallSeconds":120,"perAttemptSeconds":60,"firstTokenSeconds":45},
             "hedging":{"enabled":false,"delaySeconds":0.8,"maxParallel":2},
             "budget":{"degradeToFreeTargets":true},
             "defaults":{"systemPromptMode":"prepend"},
             "requiredCapabilities":[],"createdAt":"2026-09-01T00:00:00Z",
             "updatedAt":"2026-09-01T00:00:00Z"}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let lm = try decoder.decode(LogicalModel.self, from: Data(json.utf8))
            try expectEqual(lm.name, "smart")
            try expectNil(lm.constraints)
        }
    }
}
