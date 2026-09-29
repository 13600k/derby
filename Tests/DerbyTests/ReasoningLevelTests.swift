import Foundation
@testable import DerbyCore

func registerReasoningLevelTests() {

    /// Nothing from this machine's models.dev cache may fill a gap the fixture
    /// left on purpose.
    func withEmptyCatalog(_ body: () throws -> Void) rethrows {
        RemoteModelCatalog.shared.clearForTesting()
        try body()
    }

    func reasoner(_ id: String, levels: [String]?) -> PhysicalModel {
        var model = Fixture.model(id, caps: [.text, .streaming, .tools, .reasoning])
        model.capabilities.supportedReasoningEfforts = levels
        return model
    }

    func strings(_ value: JSONValue?) -> [String]? {
        value?.arrayValue?.compactMap { $0.stringValue }
    }

    func listing(_ models: [PhysicalModel],
                 constraints: LogicalModelConstraints? = nil) throws -> JSONValue {
        let accounts = models.enumerated().map { i, m in Fixture.account("Account \(i)", models: [m]) }
        var logical = Fixture.logical("smart", accounts: accounts)
        logical.constraints = constraints
        let json = OpenAIResponseWriter.modelsList(
            Fixture.snapshot(Fixture.config(accounts: accounts, logicalModels: [logical])))
        return try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "smart" })
    }

    suite("Reasoning levels / per model") {
        test("a provider's vocabulary is translated into the one the API parses") {
            // `none` is what `minimal` reaches on such a model, and a level the
            // request parser has no case for would be dropped on arrival.
            let caps = ModelCapabilities(
                supportedReasoningEfforts: ["max", "none", "default", "low", "xhigh", "medium", "high"])
            try expectEqual(caps.acceptedReasoningEfforts, [.minimal, .low, .medium, .high, .xhigh, .max])
            try expectEqual(caps.clampEffort(.minimal), "none", "the advertised level must reach the model's own")
        }

        test("unknown levels are not the same as none") {
            try expectNil(ModelCapabilities(supportedReasoningEfforts: nil).acceptedReasoningEfforts)
            try expectNil(ModelCapabilities(supportedReasoningEfforts: []).acceptedReasoningEfforts,
                          "an empty list is how clampEffort spells unknown, too")
            let refuses = ModelCapabilities(unsupportedParameters: [.reasoningEffort],
                                            supportedReasoningEfforts: ["low"])
            try expectEqual(refuses.acceptedReasoningEfforts, [])
        }
    }

    suite("Reasoning levels / logical model") {
        test("only levels every target accepts are advertised, weakest first") {
            try withEmptyCatalog {
                let entry = try listing([
                    reasoner("reasoner-a", levels: ["xhigh", "ultra", "low", "max", "high", "medium"]),
                    reasoner("reasoner-b", levels: ["none", "low", "medium", "high", "xhigh", "max"]),
                ])
                let shared = ["low", "medium", "high", "xhigh", "max"]
                try expectEqual(strings(entry["derby"]?["reasoning_efforts"]), shared)
                // Hoisted beside `context_window`, where most clients look.
                try expectEqual(strings(entry["reasoning_efforts"]), shared)
            }
        }

        test("each target and the active model carry their own levels") {
            try withEmptyCatalog {
                let entry = try listing([
                    reasoner("reasoner-a", levels: ["low", "medium", "high", "xhigh", "max", "ultra"]),
                    reasoner("reasoner-b", levels: ["none", "low", "medium"]),
                ])
                let targets = entry["derby"]?["targets"]?.arrayValue ?? []
                let b = try expectNotNil(targets.first { $0["id"]?.stringValue == "reasoner-b" })
                try expectEqual(strings(b["reasoning_efforts"]), ["minimal", "low", "medium"])
                try expectEqual(strings(entry["derby"]?["active_model"]?["reasoning_efforts"]),
                                ["low", "medium", "high", "xhigh", "max", "ultra"])
                try expectEqual(strings(entry["reasoning_efforts"]), ["low", "medium"])
            }
        }

        test("one target with unknown levels means no promise at all") {
            try withEmptyCatalog {
                let entry = try listing([
                    reasoner("reasoner-a", levels: ["low", "medium", "high"]),
                    reasoner("reasoner-unknown", levels: nil),
                ])
                try expectNil(entry["reasoning_efforts"], "an unknown target could exclude any level")
                try expectNil(entry["derby"]?["reasoning_efforts"])
            }
        }

        test("targets with nothing in common advertise that nothing is shared") {
            try withEmptyCatalog {
                let entry = try listing([
                    reasoner("reasoner-a", levels: ["low"]),
                    reasoner("reasoner-b", levels: ["high"]),
                ])
                try expectEqual(strings(entry["reasoning_efforts"]), [])
            }
        }

        test("a group that withholds reasoning offers no level of it") {
            try withEmptyCatalog {
                let entry = try listing(
                    [reasoner("reasoner-a", levels: ["low", "medium"])],
                    constraints: LogicalModelConstraints(allowedCapabilities: [.text, .streaming, .tools]))
                try expectEqual(entry["derby"]?["supports_reasoning"]?.boolValue, false)
                try expectEqual(strings(entry["reasoning_efforts"]), [])
            }
        }
    }

    /// Verbatim from the Qwen 3.8 template that both llama.cpp and Ollama serve
    /// on this machine: the part that names its levels, and the part that
    /// renders an assistant turn's tool calls.
    let qwenTemplate = #"""
    {%- set reasoning_instructions = '' %}
    {%- if enable_thinking is undefined or enable_thinking is true %}
        {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
        {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
            {{- raise_exception('Unexpected reasoning effort ' ~ reasoning_effort ~ '. Supported types are xhigh (default), medium, and low.') }}
        {%- endif %}
    {%- endif %}
            {%- if message.tool_calls and message.tool_calls is iterable and message.tool_calls is not mapping %}
                {%- for tool_call in message.tool_calls %}
    """#

    func jsonString(_ value: JSONValue) throws -> String {
        String(decoding: try value.stableJSONData(), as: UTF8.self)
    }

    suite("Reasoning levels / local servers") {
        test("a template's own levels are read, with its off switch") {
            try expectEqual(ChatTemplateFacts.reasoningEfforts(in: qwenTemplate),
                            ["none", "low", "medium", "xhigh"])
            try expectEqual(ModelCapabilities(supportedReasoningEfforts: ["none", "low", "medium", "xhigh"])
                                .acceptedReasoningEfforts,
                            [.minimal, .low, .medium, .xhigh])
            // Reading the variable without checking it names no levels.
            try expectNil(ChatTemplateFacts.reasoningEfforts(
                in: "{% if reasoning_effort %}Reasoning: {{ reasoning_effort }}{% endif %}"))
        }

        test("a template that renders every tool call can be asked for several") {
            try expect(ChatTemplateFacts.rendersParallelToolCalls(qwenTemplate))
            try expect(ChatTemplateFacts.rendersParallelToolCalls("{{- range .ToolCalls }}{{ .Function.Name }}{{ end }}"))
            try expect(!ChatTemplateFacts.rendersParallelToolCalls("{{ message.tool_calls[0].function.name }}"))
        }

        test("Ollama discovery reads the template /api/tags leaves out") {
            // Ollama states `tools` and `thinking` but neither the levels nor
            // parallel calls, so the same weights looked lesser than on llama.cpp.
            RemoteModelCatalog.shared.clearForTesting()
            let transport = MockTransport()
            transport.stub("/api/tags", json: """
            {"models":[
              {"model":"smtek/Qwen3.8-27B:Q4_K_M","details":{"family":"qwen35","context_length":262144},
               "capabilities":["tools","thinking","completion"]},
              {"model":"nomic-embed-text:latest","details":{"embedding_length":768},
               "capabilities":["embedding"]}]}
            """)
            transport.stub("/api/show", json: try jsonString(.object(["template": .string(qwenTemplate)])))
            var account = Fixture.account("Ollama", kind: .ollama, models: [])
            account.baseURLOverride = "http://127.0.0.1:11434/v1"
            let ctx = ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                                      credentials: CredentialCache())
            let models = try await OpenAIAdapter().listModels(ctx)
            let qwen = try expectNotNil(models.first { $0.id.hasPrefix("smtek/") }?.capabilities)
            try expectEqual(qwen.supportedReasoningEfforts, ["none", "low", "medium", "xhigh"])
            try expect(qwen.flags.contains(.parallelTools))
            try expect(!qwen.flags.contains(.vision), "Ollama said no vision, and the template cannot overrule it")
            let shown = transport.requests.filter { $0.url.path == "/api/show" }
            try expectEqual(shown.count, 1, "an embedding model has no chat template worth fetching")
            try expectEqual(shown.first?.body?["model"]?.stringValue, "smtek/Qwen3.8-27B:Q4_K_M")
        }

        test("llama.cpp's levels come from the template /props publishes") {
            RemoteModelCatalog.shared.clearForTesting()
            let transport = MockTransport()
            transport.stub("/models", json: """
            {"object":"list","data":[{"id":"Qwen3.8-27B","object":"model","owned_by":"llamacpp"}]}
            """)
            transport.stub("/props", json: try jsonString(.object(["chat_template": .string(qwenTemplate)])))
            var account = Fixture.account("dell", kind: .llamaCpp, models: [])
            account.baseURLOverride = "http://127.0.0.1:8080/v1"
            let ctx = ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                                      credentials: CredentialCache())
            let caps = try expectNotNil(try await OpenAIAdapter().listModels(ctx).first?.capabilities)
            try expectEqual(caps.supportedReasoningEfforts, ["none", "low", "medium", "xhigh"])
        }

        test("a local server does not borrow another host's levels") {
            let sample = """
            {"openrouter":{"id":"openrouter","models":{
               "qwen3.8-27b":{"id":"qwen3.8-27b","reasoning":true,"tool_call":true,
                 "reasoning_options":[{"type":"effort","values":["none","low","medium"]}],
                 "modalities":{"input":["text"],"output":["text"]},"limit":{"context":262144}}}}}
            """
            _ = RemoteModelCatalog.shared.loadForTesting(Data(sample.utf8))
            defer { RemoteModelCatalog.shared.clearForTesting() }
            try expectNil(ModelCatalog.metadata(for: "Qwen3.8-27B", kind: .ollama)
                            .capabilities.supportedReasoningEfforts)
            // The host that published them keeps them.
            try expectEqual(ModelCatalog.metadata(for: "qwen3.8-27b", kind: .openrouter)
                                .capabilities.supportedReasoningEfforts, ["none", "low", "medium"])
        }

        test("the level reaches the template, clamped to the ones it takes") {
            // Before, only the thinking switch was sent, so `low` ran at `xhigh`.
            let caps = ModelCapabilities(flags: [.text, .reasoning],
                                         supportedReasoningEfforts: ["none", "low", "medium", "xhigh"])
            let account = Fixture.account("dell", kind: .llamaCpp, models: [])
            func kwargs(_ effort: ReasoningEffort, _ caps: ModelCapabilities?) throws -> JSONValue? {
                var request = CanonicalRequest(requestedModel: "Qwen 3.8")
                request.reasoning = ReasoningControls(effort: effort)
                return try OpenAIAdapter().buildChatBody(
                    request, model: "Qwen3.8-27B", quirks: OpenAIQuirks.forKind(.llamaCpp, account: account),
                    stream: false, capabilities: caps)["chat_template_kwargs"]
            }
            try expectEqual(try kwargs(.low, caps)?["reasoning_effort"]?.stringValue, "low")
            try expectEqual(try kwargs(.low, caps)?["enable_thinking"]?.boolValue, true)
            try expectEqual(try kwargs(.high, caps)?["reasoning_effort"]?.stringValue, "medium",
                            "the template raises on a level it does not name")
            try expectEqual(try kwargs(.ultra, caps)?["reasoning_effort"]?.stringValue, "xhigh")
            try expectEqual(try kwargs(.minimal, caps)?["enable_thinking"]?.boolValue, false)
            try expectNil(try kwargs(.minimal, caps)?["reasoning_effort"])
            try expectNil(try kwargs(.low, nil)?["reasoning_effort"], "unknown levels are never guessed at")
        }
    }

    suite("Reasoning levels / ChatGPT subscription") {
        test("the Codex catalog's levels are stated, so the API's row cannot stand in") {
            // The OpenAI API and the ChatGPT backend are different services that
            // happen to share a slug. Left unstated, discovery filled the
            // backend's levels from the API's row and advertised `none`…`max`.
            let codex = """
            {"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","priority":1,
              "visibility":"list","supported_in_api":true,"default_reasoning_level":"medium",
              "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},
                                            {"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]}]}
            """
            let api = """
            {"openai":{"id":"openai","models":{
               "gpt-5.6-sol":{"id":"gpt-5.6-sol","reasoning":true,"tool_call":true,
                 "reasoning_options":[{"type":"effort","values":["none","low","medium","high","xhigh","max"]}],
                 "modalities":{"input":["text"],"output":["text"]},
                 "limit":{"context":1050000,"output":128000}}}}}
            """
            _ = RemoteModelCatalog.shared.loadForTesting(Data(api.utf8))
            defer { RemoteModelCatalog.shared.clearForTesting() }

            let entry = try expectNotNil(CodexModelCatalog.parse(Data(codex.utf8))?.entries.first)
            let known = ModelCatalog.metadata(for: entry.slug, kind: .chatgptSubscription).capabilities
            // Exactly how discovery combines the two.
            let caps = ChatGPTCodexAdapter.capabilities(for: entry).fillingGaps(from: known)
            try expectEqual(caps.acceptedReasoningEfforts, [.low, .medium, .high, .xhigh, .max, .ultra])
        }
    }
}
