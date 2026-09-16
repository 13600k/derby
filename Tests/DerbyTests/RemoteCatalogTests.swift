import Foundation
@testable import DerbyCore

func registerRemoteCatalogTests() {

    /// A models.dev-shaped fixture. Real values, so the assertions below are the
    /// ones that were actually wrong before the live catalog existed.
    let sample = """
    {"anthropic":{"id":"anthropic","name":"Anthropic","models":{
       "claude-opus-4-8":{"id":"claude-opus-4-8","name":"Claude Opus 4.8","family":"claude-opus",
         "description":"Top tier","attachment":true,"reasoning":true,"tool_call":true,
         "structured_output":true,"temperature":false,"release_date":"2026-05-28",
         "reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],
         "modalities":{"input":["text","image","pdf"],"output":["text"]},
         "limit":{"context":1000000,"output":128000},
         "cost":{"input":10,"output":50,"cache_read":1,"cache_write":12.5}},
       "claude-haiku-4-5":{"id":"claude-haiku-4-5","name":"Claude Haiku 4.5","family":"claude-haiku",
         "reasoning":true,"tool_call":true,"structured_output":true,
         "modalities":{"input":["text","image"],"output":["text"]},
         "limit":{"context":200000,"output":64000},
         "cost":{"input":1,"output":5}}}},
     "openai":{"id":"openai","name":"OpenAI","models":{
       "gpt-5.6-sol":{"id":"gpt-5.6-sol","name":"GPT-5.6-Sol","family":"gpt-5.6",
         "reasoning":true,"tool_call":true,"structured_output":true,
         "modalities":{"input":["text","image","pdf"],"output":["text"]},
         "limit":{"context":1050000,"output":128000},
         "cost":{"input":1.25,"output":10}}}},
     "openrouter":{"id":"openrouter","name":"OpenRouter","models":{
       "anthropic/claude-opus-4-8":{"id":"anthropic/claude-opus-4-8","name":"Claude Opus 4.8 (OR)",
         "reasoning":true,"tool_call":true,
         "modalities":{"input":["text"],"output":["text"]},
         "limit":{"context":900000,"output":64000}},
       "qwen3.8-27b":{"id":"qwen3.8-27b","name":"Qwen3.8 27B",
         "tool_call":true,
         "modalities":{"input":["text"],"output":["text"]},
         "limit":{"context":262144,"output":16384}}}}}
    """

    func withCatalog(_ body: () throws -> Void) rethrows {
        _ = RemoteModelCatalog.shared.loadForTesting(Data(sample.utf8))
        defer { RemoteModelCatalog.shared.clearForTesting() }
        try body()
    }

    suite("Remote catalog / cross-provider fallback") {
        test("a local server does not inherit another host's output cap") {
            // A vLLM box serving qwen3.8-27b is listed under no provider in the
            // index, so the lookup falls through to whoever else publishes the
            // id. Their max output is *their* policy — the index carries caps
            // from 16k to 262k for these same weights — and adopting it made a
            // server that imposes no limit report 16k.
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("Qwen3.8-27B", kind: .vllm))
                try expect(!entry.matchedOwnProvider)
                // The window is a property of the model, so it still applies.
                try expectEqual(entry.capabilities.contextWindow, 262_144)
                try expectNil(entry.capabilities.maxOutputTokens,
                              "a stranger's output cap was adopted anyway")
                // And the same through the layer the importer actually calls.
                let metadata = ModelCatalog.metadata(for: "Qwen3.8-27B", kind: .vllm)
                try expectNil(metadata.capabilities.maxOutputTokens)
            }
        }

        test("a model listed under the account's own provider keeps its cap") {
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("claude-opus-4-8", kind: .anthropic))
                try expect(entry.matchedOwnProvider)
                try expectEqual(entry.capabilities.maxOutputTokens, 128_000)
            }
        }
    }

    suite("Remote catalog / parsing") {
        test("a frontier model gets the window its provider never reports") {
            // Anthropic's /v1/models returns an id and a display name — no window.
            // Before this catalog, claude-opus-4-8 routed as an unknown 200k model.
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("claude-opus-4-8", kind: .anthropic))
                try expectEqual(entry.contextWindow, 1_000_000)
                try expectEqual(entry.maxOutputTokens, 128_000)
                let caps = entry.capabilities
                try expect(caps.flags.contains(.tools))
                try expect(caps.flags.contains(.vision), "input modalities include image")
                try expect(caps.flags.contains(.reasoning))
                try expect(caps.flags.contains(.jsonSchema))
                try expectEqual(caps.source, .discovered)
            }
        }

        test("pricing is read per million tokens") {
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("claude-opus-4-8", kind: .anthropic))
                let pricing = try expectNotNil(entry.pricing)
                try expectEqual(pricing.inputPerMTok, 10)
                try expectEqual(pricing.outputPerMTok, 50)
                try expectEqual(pricing.cachedInputPerMTok, 1)
            }
        }

        test("a dated snapshot resolves to its base model") {
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("claude-haiku-4-5-20251001", kind: .anthropic))
                try expectEqual(entry.contextWindow, 200_000, "not every model is a million")
            }
        }

        test("a subscription account resolves to the vendor behind it") {
            try withCatalog {
                let viaSubscription = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("gpt-5.6-sol", kind: .chatgptSubscription))
                try expectEqual(viaSubscription.contextWindow, 1_050_000)
                let viaAPI = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("claude-opus-4-8", kind: .anthropicSubscription))
                try expectEqual(viaAPI.contextWindow, 1_000_000)
            }
        }

        test("the vendor's own entry wins over an aggregator's copy") {
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("claude-opus-4-8", kind: .anthropic))
                try expectEqual(entry.contextWindow, 1_000_000, "not OpenRouter's 900k copy")
            }
        }

        test("an aggregator's namespaced id still matches") {
            try withCatalog {
                let entry = try expectNotNil(
                    RemoteModelCatalog.shared.lookup("anthropic/claude-opus-4-8", kind: .openrouter))
                try expect(entry.contextWindow != nil)
            }
        }

        test("id candidates strip tags, namespaces and date suffixes") {
            let ollama = RemoteModelCatalog.candidateIDs(for: "qwen3.5:9b")
            try expect(ollama.contains("qwen3.5"))
            let dated = RemoteModelCatalog.candidateIDs(for: "claude-sonnet-4-5-20250929")
            try expect(dated.contains("claude-sonnet-4-5"))
            let namespaced = RemoteModelCatalog.candidateIDs(for: "vendor/model-x")
            try expect(namespaced.contains("model-x"))
            // A version-looking suffix that is not a date must survive.
            try expect(!RemoteModelCatalog.candidateIDs(for: "gpt-5.6-sol").contains("gpt-5.6"))
        }

        test("an unknown model yields nothing rather than a guess") {
            try withCatalog {
                try expectNil(RemoteModelCatalog.shared.lookup("not-a-real-model", kind: .openai))
            }
        }

        test("malformed data leaves the catalog empty rather than crashing") {
            try expect(!RemoteModelCatalog.shared.loadForTesting(Data("{ not json".utf8)))
            RemoteModelCatalog.shared.clearForTesting()
            try expectNil(RemoteModelCatalog.shared.lookup("claude-opus-4-8", kind: .anthropic))
        }
    }

    suite("Remote catalog / precedence") {
        test("the live catalog outranks the bundled table") {
            try withCatalog {
                // The bundled table has claude-opus-4 at 200k; the live index says 1M.
                let metadata = ModelCatalog.metadata(for: "claude-opus-4-8", kind: .anthropic)
                try expectEqual(metadata.capabilities.contextWindow, 1_000_000)
                try expect(metadata.capabilities.flags.contains(.tools))
            }
        }

        test("the bundled table still answers when the catalog is empty") {
            RemoteModelCatalog.shared.clearForTesting()
            let metadata = ModelCatalog.metadata(for: "claude-sonnet-4-5-20250929", kind: .anthropic)
            try expect(metadata.capabilities.contextWindow != nil, "offline must still work")
            try expect(metadata.capabilities.flags.contains(.tools))
        }

        test("subscription and local targets stay flat-rate despite list prices") {
            try withCatalog {
                let subscription = ModelCatalog.metadata(for: "claude-opus-4-8", kind: .anthropicSubscription)
                try expectEqual(subscription.pricing?.isFlatRate, true,
                                "a subscription has no marginal per-token cost")
                let metered = ModelCatalog.metadata(for: "claude-opus-4-8", kind: .anthropic)
                try expectEqual(metered.pricing?.inputPerMTok, 10)
            }
        }

        test("a model with no bundled entry still gets a sensible quality score") {
            try withCatalog {
                let flagship = ModelCatalog.metadata(for: "gpt-5.6-sol", kind: .openai)
                try expect(flagship.quality > 60, "a 1M-context reasoning model should rank above default")
                try expect(flagship.quality <= 98)
            }
        }
    }

    suite("Remote catalog / self-healing") {
        test("a stored guess is re-resolved when the catalog improves") {
            // The user's config held claude-opus-4-8 at the bundled 200k. Nothing
            // should have to be re-discovered for that to be corrected.
            var stale = PhysicalModel(modelID: "claude-opus-4-8", enabled: true,
                                      capabilities: ModelCapabilities(flags: [.text, .streaming],
                                                                      contextWindow: 200_000,
                                                                      source: .builtin))
            stale.qualityScore = 90
            let account = Fixture.account("Claude", kind: .anthropic, models: [stale])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("smart", accounts: [account])])
            try withCatalog {
                let target = try expectNotNil(
                    Fixture.snapshot(config).logicalModel(named: "smart")?.targets.first)
                try expectEqual(target.capabilities.contextWindow, 1_000_000,
                                "a builtin guess must be re-derived, not frozen")
                try expect(target.capabilities.flags.contains(.tools))
            }
        }

        test("a fact the provider itself reported is never overwritten") {
            let discovered = PhysicalModel(
                modelID: "claude-opus-4-8", enabled: true,
                capabilities: ModelCapabilities(flags: [.text, .streaming, .tools],
                                                contextWindow: 123_456, source: .discovered))
            let account = Fixture.account("Claude", kind: .anthropic, models: [discovered])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("smart", accounts: [account])])
            try withCatalog {
                let target = try expectNotNil(
                    Fixture.snapshot(config).logicalModel(named: "smart")?.targets.first)
                try expectEqual(target.capabilities.contextWindow, 123_456)
            }
        }

        test("a user override still beats everything") {
            var model = PhysicalModel(modelID: "claude-opus-4-8", enabled: true,
                                      capabilities: ModelCapabilities(flags: [.text], source: .builtin))
            model.capabilityOverrides.contextWindow = 64_000
            let account = Fixture.account("Claude", kind: .anthropic, models: [model])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("smart", accounts: [account])])
            try withCatalog {
                let target = try expectNotNil(
                    Fixture.snapshot(config).logicalModel(named: "smart")?.targets.first)
                try expectEqual(target.capabilities.contextWindow, 64_000)
            }
        }
    }

    suite("Logical models / no required capabilities") {
        test("a group is defined by its targets, not by a demand that can empty it") {
            // Requiring a capability no target has could only ever break the group,
            // so the setting is gone and is not applied even if stored.
            let plain = Fixture.account("Plain", models: [
                Fixture.model("p", caps: [.text, .streaming], context: 32_000)])
            var lm = Fixture.logical("coding", accounts: [plain])
            lm.requiredCapabilities = [.tools, .vision]
            let config = Fixture.config(accounts: [plain], logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            try expectEqual(decision.plan.attempts.count, 1,
                            "a stored requirement must no longer empty the group")
        }

        test("a request's own needs still filter targets") {
            let plain = Fixture.account("Plain", models: [
                Fixture.model("p", caps: [.text, .streaming], context: 32_000)])
            let config = Fixture.config(accounts: [plain],
                                        logicalModels: [Fixture.logical("coding", accounts: [plain])])
            var request = CanonicalRequest(requestedModel: "coding")
            request.tools = [CanonicalTool(name: "f")]
            _ = try await expectFailure(.capabilityMismatch) {
                _ = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            }
        }
    }
}

func registerParameterSupportTests() {
    /// Mirrors the real catalog: modern reasoning models set `temperature: false`.
    let sample = """
    {"anthropic":{"id":"anthropic","models":{
       "claude-sonnet-5":{"id":"claude-sonnet-5","reasoning":true,"tool_call":true,
         "structured_output":true,"temperature":false,
         "reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],
         "modalities":{"input":["text","image"],"output":["text"]},
         "limit":{"context":1000000,"output":128000}},
       "claude-sonnet-4-6":{"id":"claude-sonnet-4-6","reasoning":true,"tool_call":true,
         "structured_output":true,"temperature":true,
         "modalities":{"input":["text","image"],"output":["text"]},
         "limit":{"context":1000000,"output":128000}}}},
     "openai":{"id":"openai","models":{
       "gpt-5.6-sol":{"id":"gpt-5.6-sol","reasoning":true,"tool_call":true,
         "structured_output":true,"temperature":false,
         "reasoning_options":[{"type":"effort","values":["none","low","medium","high","xhigh","max"]}],
         "modalities":{"input":["text","image"],"output":["text"]},
         "limit":{"context":1050000,"output":128000}}}}}
    """

    func withCatalog(_ body: () throws -> Void) rethrows {
        _ = RemoteModelCatalog.shared.loadForTesting(Data(sample.utf8))
        defer { RemoteModelCatalog.shared.clearForTesting() }
        try body()
    }

    func ctx(_ account: ProviderAccount, capabilities: ModelCapabilities?) -> ProviderContext {
        ProviderContext(account: account, transport: MockTransport(), secrets: InMemorySecretStore(),
                        credentials: CredentialCache(), attemptTimeout: 5,
                        modelCapabilities: capabilities)
    }

    suite("Parameters / model support") {
        test("a model that rejects temperature is recorded as rejecting it") {
            // "temperature is deprecated" was Derby sending a parameter the model
            // had already declared it would not take.
            try withCatalog {
                let caps = ModelCatalog.metadata(for: "claude-sonnet-5", kind: .anthropic).capabilities
                try expect(!caps.allows(.temperature))
                try expect(!caps.allows(.topP), "sampling parameters go together")
                try expect(caps.allows(.maxTokens), "unrelated parameters are unaffected")
                try expect(caps.allows(.stop))
            }
        }

        test("a model that accepts temperature is left alone") {
            try withCatalog {
                let caps = ModelCatalog.metadata(for: "claude-sonnet-4-6", kind: .anthropic).capabilities
                try expect(caps.allows(.temperature))
            }
        }

        test("a model nothing is known about still receives every parameter") {
            RemoteModelCatalog.shared.clearForTesting()
            let caps = ModelCatalog.metadata(for: "some-unlisted-model", kind: .openAICompatible).capabilities
            try expect(caps.allows(.temperature), "a deny-list must never guess")
            try expect(caps.unsupportedParameters.isEmpty)
        }

        test("the OpenAI dialect omits a rejected temperature") {
            try withCatalog {
                let caps = ModelCatalog.metadata(for: "gpt-5.6-sol", kind: .openai).capabilities
                var request = CanonicalRequest(requestedModel: "l")
                request.temperature = 0.5
                request.topP = 0.9
                request.maxOutputTokens = 100
                let body = try OpenAIAdapter().buildChatBody(request, model: "gpt-5.6-sol",
                                                             quirks: OpenAIQuirks(), stream: false,
                                                             capabilities: caps)
                try expectNil(body["temperature"], "sending this would fail the request")
                try expectNil(body["top_p"])
                try expectEqual(body["max_tokens"]?.intValue, 100, "other parameters still go")
            }
        }

        test("the Anthropic adapter omits a rejected temperature") {
            try withCatalog {
                let caps = ModelCatalog.metadata(for: "claude-sonnet-5", kind: .anthropic).capabilities
                let account = Fixture.account("Claude", kind: .anthropic,
                                              models: [Fixture.model("claude-sonnet-5")])
                var request = CanonicalRequest(requestedModel: "l")
                request.temperature = 0.7
                request.maxOutputTokens = 256
                let body = try AnthropicAdapter(oauth: false)
                    .buildBody(request, model: "claude-sonnet-5",
                               ctx: ctx(account, capabilities: caps), stream: false)
                try expectNil(body["temperature"])
                try expectEqual(body["max_tokens"]?.intValue, 256)
            }
        }

        test("a model that accepts temperature still receives it") {
            try withCatalog {
                let caps = ModelCatalog.metadata(for: "claude-sonnet-4-6", kind: .anthropic).capabilities
                var request = CanonicalRequest(requestedModel: "l")
                request.temperature = 0.7
                let body = try OpenAIAdapter().buildChatBody(request, model: "claude-sonnet-4-6",
                                                             quirks: OpenAIQuirks(), stream: false,
                                                             capabilities: caps)
                try expectEqual(body["temperature"]?.doubleValue, 0.7)
            }
        }

        test("reasoning effort is clamped to the levels a model publishes") {
            try withCatalog {
                let sol = ModelCatalog.metadata(for: "gpt-5.6-sol", kind: .openai).capabilities
                try expectEqual(sol.clampEffort(.max), "max")
                try expectEqual(sol.clampEffort(.ultra), "max", "ultra steps down to the strongest offered")
                // OpenAI's vocabulary spells the weakest level "none".
                try expectEqual(sol.clampEffort(.minimal), "none")

                let sonnet = ModelCatalog.metadata(for: "claude-sonnet-5", kind: .anthropic).capabilities
                try expectEqual(sonnet.clampEffort(.ultra), "max")
                try expectEqual(sonnet.clampEffort(.medium), "medium")
            }
        }

        test("an enumerated parameter list is treated as authoritative") {
            // OpenRouter publishes exactly what it accepts, so anything absent is
            // rejected rather than merely unmentioned.
            let item = try expectNotNil(JSONValue.parse("""
            {"id":"vendor/m","context_length":100000,
             "supported_parameters":["tools","max_tokens","reasoning"]}
            """))
            let model = try expectNotNil(OpenAIAdapter().parseListedModel(item, kind: .openrouter))
            let caps = try expectNotNil(model.capabilities)
            try expect(!caps.allows(.temperature))
            try expect(!caps.allows(.seed))
            try expect(caps.allows(.maxTokens))
            try expect(caps.allows(.reasoningEffort))
        }

        test("a rejection known to either source is honoured after merging") {
            let discovered = ModelCapabilities(flags: [.text], source: .discovered)
            let known = ModelCapabilities(flags: [.text], unsupportedParameters: [.temperature])
            try expect(!discovered.completed(by: known).allows(.temperature),
                       "sending a rejected parameter is a hard error, so the union is the safe merge")
        }

        test("clients are told which parameters to omit") {
            try withCatalog {
                let account = Fixture.account("Claude", kind: .anthropic, models: [
                    PhysicalModel(modelID: "claude-sonnet-5", enabled: true,
                                  capabilities: ModelCapabilities(flags: [], source: .unknown))])
                let config = Fixture.config(accounts: [account],
                                            logicalModels: [Fixture.logical("smart", accounts: [account])])
                let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(config))
                let entry = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "smart" })
                let rejected = (entry["derby"]?["unsupported_parameters"]?.arrayValue ?? [])
                    .compactMap { $0.stringValue }
                try expect(rejected.contains("temperature"))
                let efforts = (entry["derby"]?["reasoning_efforts"]?.arrayValue ?? []).compactMap { $0.stringValue }
                try expect(efforts.contains("xhigh"))
            }
        }
    }
}
