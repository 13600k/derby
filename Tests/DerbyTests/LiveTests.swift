import Foundation
@testable import DerbyCore

/// Checks against this machine's real providers. Registered only when
/// `DERBY_LIVE=1`, because every other suite must pass with no network at all.
///
///     DERBY_LIVE=1 swift run DerbyTests Live
///
/// It reads the installed configuration, works from a **copy** of it, and runs
/// its own gateway on an ephemeral port, so a running Derby and its config are
/// never touched. Groups whose provider is not configured are skipped, not
/// failed — this suite describes one machine, and machines differ.
func registerLiveTests() {

    let question = "What is the weather in Paris right now? Call get_weather, then answer in one short sentence."
    let weatherTool = JSONValue.object([
        "type": .string("function"),
        "function": .object([
            "name": .string("get_weather"),
            "description": .string("Current weather for a city"),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object(["city": .object(["type": .string("string")])]),
                "required": .array([.string("city")]),
            ]),
        ]),
    ])

    func chat(_ port: Int, _ body: JSONValue, seconds: Double = 300) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Derby-Live", forHTTPHeaderField: "x-derby-client")
        request.httpBody = Data(body.compactJSONString.utf8)
        request.timeoutInterval = seconds
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TestFailure(message: "gateway answered \((response as? HTTPURLResponse)?.statusCode ?? 0): "
                              + String(String(decoding: data, as: UTF8.self).prefix(400)),
                              file: #fileID, line: #line)
        }
        return try expectNotNil(JSONValue.parse(String(decoding: data, as: UTF8.self)), "response was not JSON")
    }

    func turnOne(_ model: String) -> JSONValue {
        .object([
            "model": .string(model),
            "messages": .array([.object(["role": .string("user"), "content": .string(question)])]),
            "tools": .array([weatherTool]),
            "reasoning_effort": .string("medium"),
            "reasoning": .object(["effort": .string("medium"), "summary": .string("auto")]),
            "max_tokens": .number(500),
        ])
    }

    /// The second turn exactly as a Chat Completions client sends it: the
    /// assistant's tool call and the result, with no reasoning — the client
    /// dialect has nowhere to keep it.
    func turnTwo(_ model: String, call: JSONValue, result: String) -> JSONValue {
        .object([
            "model": .string(model),
            "messages": .array([
                .object(["role": .string("user"), "content": .string(question)]),
                .object(["role": .string("assistant"), "tool_calls": .array([call])]),
                .object(["role": .string("tool"),
                         "tool_call_id": call["id"] ?? .string(""),
                         "content": .string(result)]),
            ]),
            "tools": .array([weatherTool]),
            "reasoning_effort": .string("medium"),
            "reasoning": .object(["effort": .string("medium"), "summary": .string("auto")]),
            "max_tokens": .number(500),
        ])
    }

    /// The Responses dialect, which is the one that can ask for a reasoning
    /// summary — and the one a Codex-style client speaks.
    func responsesCall(_ port: Int, _ body: JSONValue, seconds: Double = 300) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(body.compactJSONString.utf8)
        request.timeoutInterval = seconds
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TestFailure(message: "gateway answered \((response as? HTTPURLResponse)?.statusCode ?? 0): "
                              + String(String(decoding: data, as: UTF8.self).prefix(400)),
                              file: #fileID, line: #line)
        }
        return try expectNotNil(JSONValue.parse(String(decoding: data, as: UTF8.self)), "response was not JSON")
    }

    func firstToolCall(_ answer: JSONValue) throws -> JSONValue {
        try expectNotNil(answer["choices"]?[0]?["message"]?["tool_calls"]?[0],
                         "the model answered without calling the tool: "
                         + (answer["choices"]?[0]?["message"]?["content"]?.stringValue ?? "—"))
    }

    func reasoningOf(_ answer: JSONValue) -> String {
        answer["choices"]?[0]?["message"]?["reasoning_content"]?.stringValue ?? ""
    }
    func contentOf(_ answer: JSONValue) -> String {
        answer["choices"]?[0]?["message"]?["content"]?.stringValue ?? ""
    }
    func handoff(_ answer: JSONValue) -> JSONValue? { answer["x_derby"]?["handoff"] }

    /// The tool answered "18°C, light rain"; a model may quote either half, or
    /// spell the number out. What matters is that the result reached it.
    func usesToolResult(_ answer: String) -> Bool {
        let lower = answer.lowercased()
        return lower.contains("18") || lower.contains("eighteen") || lower.contains("rain")
    }

    /// The reasoning a request actually carried to an OpenAI-style server.
    func replayedReasoning(_ body: JSONValue) throws -> String? {
        let assistant = try expectNotNil(body["messages"]?.arrayValue?.first { $0["role"]?.stringValue == "assistant" },
                                         "no assistant turn was sent")
        return assistant["reasoning"]?.stringValue ?? assistant["reasoning_content"]?.stringValue
    }

    // MARK: - Lineage of the models actually configured here

    suite("Live / lineage") {
        test("the models on this machine grade as expected") {
            for id in ["qwen3.8-27b-fp8", "qwen3.6:27b", "qwen3.5:9b", "honcho-qwen3.6:27b",
                       "gpt-5.6-luna", "claude-sonnet-5"] {
                let l = ModelLineage.parse(id)
                print("      \(id) → family \(l.family), generation \(l.generation ?? "?"), "
                      + "size \(l.size ?? "?"), quant \(l.quantization ?? "—"), identity \(l.identity)")
            }
            let enzotide = ModelLineage.parse("qwen3.8-27b-fp8")
            try expectEqual(enzotide.affinity(with: .parse("qwen3.6:27b")), .sameVendor,
                            "3.8 and 3.6 are different releases, so reasoning does not cross")
            try expectEqual(enzotide.affinity(with: .parse("qwen3.8:27b-q4_K_M")), .identical,
                            "the same weights at another quantization")
            try expectEqual(enzotide.affinity(with: .parse("gpt-5.6-luna")), .foreign)
        }

        test("a locally renamed model keeps the family it was built from") {
            let tuned = ModelLineage.parse("honcho-qwen3.6:27b")
            let base = ModelLineage.parse("qwen3.6:27b")
            try expectEqual(tuned.family, "qwen")
            try expectEqual(tuned.generation, "3.6")
            try expectEqual(tuned.affinity(with: base), .sameFamily,
                            "same template, so reasoning carries — but not the same model, so it is not a copy")
            try expect(tuned.identity != base.identity, "warm-copy preference must not swap one for the other")
        }
    }

    // MARK: - What the servers report

    suite("Live / servers") {
        test("Ollama reports what it currently holds in memory") {
            let loaded = try await LiveGateway.shared.loadedModels(providerNamed: "Ollama (local)")
            print("      Ollama loaded: \(loaded?.sorted().joined(separator: ", ") ?? "nothing reported")")
            _ = try expectNotNil(loaded, "Ollama should answer /api/ps")
        }

        test("a vLLM server reports the model it is serving") {
            guard let loaded = try await LiveGateway.shared.loadedModels(providerNamed: LiveGateway.vllmAccount) else {
                print("      (skipped: no vLLM server configured)")
                return
            }
            print("      vLLM serving: \(loaded.sorted().joined(separator: ", "))")
            try expect(loaded.contains("qwen3.8-27b-fp8"))
        }

        test("a vLLM server says how busy it is") {
            guard let busy = try await LiveGateway.shared.occupancy(providerNamed: LiveGateway.vllmAccount) else {
                print("      (skipped: no vLLM server configured, or it publishes no metrics)")
                return
            }
            print("      vLLM occupancy: \(busy.summary), utilization "
                  + (busy.utilization.map { String(format: "%.2f", $0) } ?? "—")
                  + ", saturated \(busy.isSaturated)")
            try expect(!busy.isEmpty, "the server published at least one gauge Derby reads")
        }

        test("a custom OpenAI-compatible endpoint is never asked, whatever is behind it") {
            try expectNil(try await LiveGateway.shared.loadedModels(providerNamed: LiveGateway.customAccount),
                          "Derby does not guess that a custom endpoint is a server it knows")
            try expectNil(try await LiveGateway.shared.occupancy(providerNamed: LiveGateway.customAccount))
        }
    }

    // MARK: - Carrying a conversation between real models

    suite("Live / hand-off") {
        test("a model continues from its own reasoning, which the client never sent back") {
            guard let live = try await LiveGateway.shared.start(), live.has("live-vllm") else { return }
            let first = try await chat(live.port, turnOne("live-vllm"))
            let call = try firstToolCall(first)
            let reasoning = reasoningOf(first)
            print("      turn 1 reasoning: \(reasoning.prefix(110))…")
            try expect(!reasoning.isEmpty, "vLLM should return the model's reasoning")

            live.spy.clear()
            let second = try await chat(live.port, turnTwo("live-vllm", call: call, result: "18°C, light rain"))
            let sent = try expectNotNil(live.spy.lastBody(matching: "enzotide"), "nothing reached the vLLM server")
            let replayed = try replayedReasoning(sent)
            print("      replayed to the model: \((replayed ?? "—").prefix(110))…")
            try expectEqual(replayed, reasoning, "the ledger restored the reasoning the client dropped")
            try expect(usesToolResult(contentOf(second)), "the answer should use the tool result: \(contentOf(second))")
        }

        test("the same weights reached through a second server also continue the reasoning") {
            guard let live = try await LiveGateway.shared.start(),
                  live.has("live-vllm"), live.has("live-vllm-b") else { return }
            let first = try await chat(live.port, turnOne("live-vllm"))
            let call = try firstToolCall(first)
            let reasoning = reasoningOf(first)

            live.spy.clear()
            let second = try await chat(live.port, turnTwo("live-vllm-b", call: call, result: "18°C, light rain"))
            let replayed = try replayedReasoning(try expectNotNil(live.spy.lastBody(matching: "enzotide")))
            try expectEqual(replayed, reasoning, "same weights, another account: identical lineage")
            if let h = handoff(second) { print("      handoff: \(h["summary"]?.stringValue ?? "—")") }
            try expect(usesToolResult(contentOf(second)), "answer: \(contentOf(second))")
        }

        test("a custom endpoint gets the conversation but no field its server may not know") {
            guard let live = try await LiveGateway.shared.start(),
                  live.has("live-vllm"), live.has("live-custom") else { return }
            let first = try await chat(live.port, turnOne("live-vllm"))
            let call = try firstToolCall(first)

            live.spy.clear()
            let second = try await chat(live.port, turnTwo("live-custom", call: call, result: "18°C, light rain"))
            try expectNil(try replayedReasoning(try expectNotNil(live.spy.lastBody(matching: "enzotide"))),
                          "a generic openai_compatible target is sent only standard fields")
            try expect(usesToolResult(contentOf(second)), "the conversation itself still arrives intact")
        }

        test("a different release of the same family gets the conversation, not the reasoning") {
            guard let live = try await LiveGateway.shared.start(), live.has("live-vllm"), live.has("live-ollama") else { return }
            let first = try await chat(live.port, turnOne("live-vllm"))
            let call = try firstToolCall(first)

            live.spy.clear()
            let second = try await chat(live.port, turnTwo("live-ollama", call: call, result: "18°C, light rain"))
            let sent = try expectNotNil(live.spy.lastBody(matching: "11434"), "nothing reached Ollama")
            try expectNil(try replayedReasoning(sent), "qwen3.8's reasoning is not handed to qwen3.6")
            let assistant = try expectNotNil(sent["messages"]?.arrayValue?.first { $0["role"]?.stringValue == "assistant" })
            try expectEqual(assistant["tool_calls"]?[0]?["function"]?["name"]?.stringValue, "get_weather",
                            "the call itself survives intact")
            let h = try expectNotNil(handoff(second), "a model change should be reported")
            print("      handoff: \(h["summary"]?.stringValue ?? "—")")
            try expectEqual(h["affinity"]?.stringValue, "same_vendor")
            try expect((h["reasoning_withheld"]?.intValue ?? 0) >= 1)
            try expect(usesToolResult(contentOf(second)),
                       "the answer should still use the tool result: \(contentOf(second))")
        }

        test("a tool loop started by GPT is finished by Qwen, with the reasoning withheld") {
            guard let live = try await LiveGateway.shared.start(), live.has("live-gpt"), live.has("live-ollama") else { return }
            let first = try await chat(live.port, turnOne("live-gpt"))
            let call = try firstToolCall(first)

            live.spy.clear()
            let second = try await chat(live.port, turnTwo("live-ollama", call: call, result: "18°C, light rain"))
            try expectNil(try replayedReasoning(try expectNotNil(live.spy.lastBody(matching: "11434"))))
            let h = try expectNotNil(handoff(second))
            print("      handoff: \(h["summary"]?.stringValue ?? "—")")
            try expectEqual(h["affinity"]?.stringValue, "foreign")
            try expect(usesToolResult(contentOf(second)), "answer: \(contentOf(second))")
        }

        test("GPT's own encrypted reasoning goes back to GPT") {
            guard let live = try await LiveGateway.shared.start(), live.has("live-gpt") else { return }
            live.spy.watch("chatgpt.com")
            // Through the Responses dialect, where a client can ask for a
            // reasoning summary — which is how a Codex-style client talks.
            let opening = try await responsesCall(live.port, .object([
                "model": .string("live-gpt"),
                "input": .array([.object(["type": .string("message"), "role": .string("user"),
                                          "content": .string(
                    "A train leaves at 14:05 and takes 3h47m. Another leaves 40 minutes later and takes 2h58m. "
                    + "Work out which arrives first and by how many minutes, then call get_weather for Paris "
                    + "and answer in one short sentence.")])]),
                "tools": .array([.object([
                    "type": .string("function"),
                    "name": .string("get_weather"),
                    "description": .string("Current weather for a city"),
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object(["city": .object(["type": .string("string")])]),
                        "required": .array([.string("city")]),
                    ]),
                ])]),
                "reasoning": .object(["effort": .string("high"), "summary": .string("auto")]),
                "max_output_tokens": .number(900),
            ]))
            print("      responses output: "
                  + (opening["output"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }.joined(separator: ", "))
            for line in live.spy.notes() where line.contains("item=") { print("      ← \(line)") }
            let functionCall = try expectNotNil((opening["output"]?.arrayValue ?? [])
                .first { $0["type"]?.stringValue == "function_call" }, "the model did not call the tool")
            let call = JSONValue.object([
                "id": functionCall["call_id"] ?? .string(""),
                "type": .string("function"),
                "function": .object(["name": functionCall["name"] ?? .string("get_weather"),
                                     "arguments": functionCall["arguments"] ?? .string("{}")]),
            ])
            print("      turn 1: call id \(call["id"]?.stringValue ?? "—")")
            if let out = live.spy.lastBody(matching: "chatgpt.com") {
                print("      → model \(out["model"]?.stringValue ?? "—"), "
                      + "reasoning \(out["reasoning"]?.compactJSONString ?? "absent"), "
                      + "include \(out["include"]?.compactJSONString ?? "absent"), "
                      + "store \(out["store"]?.compactJSONString ?? "absent")")
            }
            for line in live.spy.notes() where line.contains("item=") || line.contains("reasoning") {
                print("      ← \(line)")
            }

            // Where a replay would stop: capture into the ledger, or the plan.
            if let ledger = await LiveGateway.shared.ledger() {
                let history = CanonicalRequest(requestedModel: "live-gpt", messages: [
                    .user(question),
                    CanonicalMessage(role: .assistant, toolCalls: [
                        CanonicalToolCall(id: call["id"]?.stringValue ?? "",
                                          name: call["function"]?["name"]?.stringValue ?? "",
                                          argumentsJSON: call["function"]?["arguments"]?.stringValue ?? "{}")]),
                    CanonicalMessage(role: .tool, content: [.text("18°C, light rain")],
                                     toolCallID: call["id"]?.stringValue),
                ])
                let restored = await ledger.annotate(history).messages[1]
                print("      ledger restored: origin \(restored.origin?.modelID ?? "—"), "
                      + "reasoning \(restored.reasoning == nil ? "none" : "yes"), "
                      + "artifacts \(restored.reasoningArtifacts.map { $0.format.rawValue })")
            }

            // Derby can only hand back what the provider issued. This backend
            // does not always return a reasoning item, and when it does not,
            // there is nothing to carry — which is not a failure.
            let asked = try expectNotNil(live.spy.lastBody(matching: "chatgpt.com"))
            try expectEqual(asked["include"]?[0]?.stringValue, "reasoning.encrypted_content",
                            "Derby always asks for reasoning it could hand back")
            guard live.spy.notes().contains(where: { $0.contains("item=reasoning") }) else {
                print("      (the backend returned no reasoning item for this turn, so none can be replayed)")
                return
            }

            live.spy.clear()
            let second = try await chat(live.port, turnTwo("live-gpt", call: call, result: "18°C, light rain"))
            let sent = try expectNotNil(live.spy.lastBody(matching: "chatgpt.com"))
            let items = try expectNotNil(sent["input"]?.arrayValue)
            let reasoningItems = items.filter { $0["type"]?.stringValue == "reasoning" }
            print("      items sent: \(items.compactMap { $0["type"]?.stringValue }.joined(separator: ", "))")
            try expect(!reasoningItems.isEmpty, "the ledger should restore the reasoning items Codex issued")
            try expect(reasoningItems.contains { $0["encrypted_content"]?.stringValue?.isEmpty == false })
            try expect(usesToolResult(contentOf(second)), "answer: \(contentOf(second))")
        }
    }

    // MARK: - Load and disconnects

    suite("Live / load") {
        test("simultaneous requests spread across two real servers") {
            guard let live = try await LiveGateway.shared.start(), live.has("live-burst") else { return }
            let answers = await withTaskGroup(of: String?.self) { group -> [String] in
                for i in 0..<4 {
                    group.addTask {
                        let body = JSONValue.object([
                            "model": .string("live-burst"),
                            "messages": .array([.object(["role": .string("user"),
                                                         "content": .string("Reply with just the number \(i).")])]),
                            "max_tokens": .number(24),
                        ])
                        return try? await chat(live.port, body)["model"]?.stringValue
                    }
                }
                var out: [String] = []
                for await answer in group { if let answer { out.append(answer) } }
                return out
            }
            print("      answered by: \(answers.sorted().joined(separator: ", "))")
            try expectEqual(answers.count, 4, "every request should have been answered")
            try expect(Set(answers).count > 1, "a burst should not pile onto one server")
        }

        test("a client that walks away stops the model generating") {
            guard let live = try await LiveGateway.shared.start(), live.has("live-ollama") else { return }
            let log = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ollama/logs/server.log")
            guard let before = try? String(contentsOf: log, encoding: .utf8) else {
                print("      (skipped: no Ollama server log on this machine)")
                return
            }
            let body = JSONValue.object([
                "model": .string("live-ollama"),
                "messages": .array([.object(["role": .string("user"),
                                             "content": .string("Write a 700 word essay about the sea.")])]),
                "stream": .bool(true),
                "max_tokens": .number(2000),
            ]).compactJSONString

            let client = RawHTTPClient(port: live.port)
            client.send("POST /v1/chat/completions HTTP/1.1\r\nhost: localhost\r\n"
                        + "content-type: application/json\r\ncontent-length: \(body.utf8.count)\r\n\r\n" + body)
            // Wait until tokens are really flowing, then vanish.
            let opening = await client.read(within: 180) { $0.components(separatedBy: "data:").count > 6 }
            try expect(opening.contains("data:"), "the stream never started: \(opening.prefix(200))")
            let left = Date()
            client.close()

            // Ollama logs a request when it finishes. Had Derby not cancelled it,
            // that line would arrive only after the whole essay was generated.
            try await eventually("Ollama finishes the abandoned request", within: 25) {
                guard let now = try? String(contentsOf: log, encoding: .utf8), now.count > before.count else { return false }
                return String(now.dropFirst(before.count)).contains("/v1/chat/completions")
            }
            print("      Ollama finished the abandoned request "
                  + String(format: "%.1f", Date().timeIntervalSince(left)) + "s after the client left")
        }
    }
}

// MARK: - The live gateway

/// Boots one gateway for the whole live suite, from a copy of the installed
/// configuration, with extra single-target groups so a test can say exactly
/// which model should answer.
actor LiveGateway {
    static let shared = LiveGateway()
    /// The same server the user reaches as a custom endpoint, declared as what
    /// it actually runs, so the vLLM-specific paths can be exercised.
    static let vllmAccount = "enzotide (as vLLM)"
    /// The same server declared as an unknown endpoint, so the conservative
    /// path is checked whatever kind the user has configured.
    static let customAccount = "enzotide (as a custom endpoint)"

    struct Running {
        let port: Int
        let spy: SpyTransport
        let groups: Set<String>
        func has(_ group: String) -> Bool {
            if groups.contains(group) { return true }
            print("      (skipped: \(group) is not configured on this machine)")
            return false
        }
    }

    private var running: Running?
    private var engine: DerbyEngine?
    private var accounts: [String: ProviderAccount] = [:]
    private var failure: String?

    /// nil when there is no usable configuration; the reason is printed once.
    func start() async throws -> Running? {
        if let running { return running }
        if let failure { print("      (skipped: \(failure))"); return nil }

        let source = ProcessInfo.processInfo.environment["DERBY_LIVE_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? AppPaths.configFile
        guard FileManager.default.fileExists(atPath: source.path) else {
            failure = "no Derby configuration at \(source.path)"
            print("      (skipped: \(failure!))")
            return nil
        }
        var config = ConfigStore(url: source).load().config

        // Its own port, no key, and never a write over the real configuration.
        config.gateway.port = 0
        config.gateway.autoStart = false
        config.gateway.requireAPIKey = false

        /// A second copy of an account, so one server can be reached as two.
        func duplicate(_ account: ProviderAccount, named name: String, kind: ProviderKind? = nil) -> ProviderAccount {
            var copy = account
            copy.id = UUID()
            copy.name = name
            if let kind { copy.kind = kind }
            copy.models = account.models.map { var m = $0; m.id = UUID(); return m }
            return copy
        }

        if let enzotide = config.providers.first(where: { $0.name == "enzotide" }) {
            config.providers.append(duplicate(enzotide, named: LiveGateway.vllmAccount, kind: .vllm))
            config.providers.append(duplicate(enzotide, named: "enzotide (as vLLM, second server)", kind: .vllm))
            config.providers.append(duplicate(enzotide, named: LiveGateway.customAccount, kind: .openAICompatible))
        }
        for account in config.providers { accounts[account.name] = account }

        var groups: Set<String> = []
        func pin(_ name: String, provider: String, model: String) {
            guard let account = accounts[provider],
                  let physical = account.models.first(where: { $0.modelID == model }) else { return }
            config.logicalModels.append(LiveGateway.group(name, targets: [(account.id, physical.id)]))
            groups.insert(name)
        }
        pin("live-custom", provider: LiveGateway.customAccount, model: "qwen3.8-27b-fp8")
        pin("live-vllm", provider: LiveGateway.vllmAccount, model: "qwen3.8-27b-fp8")
        pin("live-vllm-b", provider: "enzotide (as vLLM, second server)", model: "qwen3.8-27b-fp8")
        pin("live-ollama", provider: "Ollama (local)", model: "qwen3.6:27b")
        for chatgpt in config.providers where chatgpt.kind == .chatgptSubscription {
            guard !groups.contains("live-gpt"),
                  let model = chatgpt.models.first(where: { $0.modelID.contains("gpt-5") }) else { continue }
            config.logicalModels.append(LiveGateway.group("live-gpt", targets: [(chatgpt.id, model.id)]))
            groups.insert("live-gpt")
        }
        // Two different servers, ranked by how busy each one is.
        if let enzotide = accounts["enzotide"], let ollama = accounts["Ollama (local)"],
           let fp8 = enzotide.models.first(where: { $0.modelID == "qwen3.8-27b-fp8" }),
           let small = ollama.models.first(where: { $0.modelID == "qwen3.5:9b" }) {
            config.logicalModels.append(LiveGateway.group("live-burst",
                                                          targets: [(enzotide.id, fp8.id), (ollama.id, small.id)],
                                                          strategy: .leastLoaded))
            groups.insert("live-burst")
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        try store.save(config)

        let spy = SpyTransport(inner: URLSessionTransport.shared)
        let engine = DerbyEngine(configStore: store,
                                 secrets: InMemorySecretStore(),   // never opens the Keychain
                                 transport: spy,
                                 adapters: .default,
                                 telemetry: TelemetryStore(path: dir.appendingPathComponent("live.sqlite3").path,
                                                           settings: config.logging))
        await engine.bootstrap()
        try await engine.startGateway()
        guard case .running(let port, _) = await engine.status else {
            failure = "the live gateway did not start: \(await engine.status)"
            print("      (skipped: \(failure!))")
            return nil
        }
        print("      live gateway on 127.0.0.1:\(port), groups: \(groups.sorted().joined(separator: ", "))")
        self.engine = engine
        let running = Running(port: port, spy: spy, groups: groups)
        self.running = running
        return running
    }

    func ledger() async -> HandoffLedger? {
        _ = try? await start()
        return engine?.handoffLedger
    }

    /// Asks a configured server what it has loaded, through the real adapter.
    func loadedModels(providerNamed name: String) async throws -> Set<String>? {
        guard let ctx = try await context(providerNamed: name) else { return nil }
        return try await AdapterRegistry.default.adapter(for: ctx.account.kind).loadedModels(ctx)
    }

    /// Asks a configured server what it is working on right now.
    func occupancy(providerNamed name: String) async throws -> ServerOccupancy? {
        guard let ctx = try await context(providerNamed: name) else { return nil }
        return try await AdapterRegistry.default.adapter(for: ctx.account.kind).occupancy(ctx)
    }

    private func context(providerNamed name: String) async throws -> ProviderContext? {
        _ = try await start()
        guard let account = accounts[name] else { return nil }
        return ProviderContext(account: account, transport: URLSessionTransport.shared,
                               secrets: InMemorySecretStore(), credentials: CredentialCache(),
                               attemptTimeout: 10)
    }

    private static func group(_ name: String, targets: [(UUID, UUID)],
                              strategy: RoutingStrategyKind = .priority) -> LogicalModel {
        LogicalModel(name: name,
                     targets: targets.map { TargetRef(providerID: $0.0, modelUUID: $0.1) },
                     policy: RoutingPolicy(strategy: strategy, deterministic: true),
                     retry: RetryConfig(maxRetriesPerTarget: 0, initialBackoffSeconds: 0.1),
                     failover: strategy == .priority ? FailoverConfig(enabled: false) : .default,
                     timeouts: TimeoutConfig(overallSeconds: 300, perAttemptSeconds: 280, firstTokenSeconds: 180))
    }
}

/// Passes every provider call through untouched, keeping what was sent so a
/// test can assert on the wire rather than on Derby's own report of it.
final class SpyTransport: HTTPTransport, @unchecked Sendable {
    private let inner: any HTTPTransport
    private let lock = NSLock()
    private var sent: [(url: String, body: JSONValue)] = []
    private var watching: String?
    private var seen: [String] = []

    init(inner: any HTTPTransport) { self.inner = inner }

    /// Start noting the events a matching endpoint streams back, so a test can
    /// report what a provider really answered rather than what Derby made of it.
    func watch(_ fragment: String) { lock.lock(); watching = fragment; seen.removeAll(); lock.unlock() }
    func notes() -> [String] { lock.lock(); defer { lock.unlock() }; return seen }

    private func note(_ event: SSEEvent) {
        guard let json = event.json else { return }
        var line = json["type"]?.stringValue ?? event.event ?? "?"
        if let item = json["item"], case .object(let fields) = item {
            line += " item=\(item["type"]?.stringValue ?? "?") {\(fields.keys.sorted().joined(separator: ","))}"
        }
        lock.lock(); if seen.count < 40 { seen.append(line) }; lock.unlock()
    }

    private func record(_ request: OutboundRequest) {
        guard let body = request.body, let json = JSONValue.parse(String(decoding: body, as: UTF8.self)) else { return }
        lock.lock(); sent.append((request.url.absoluteString, json)); lock.unlock()
    }

    func clear() { lock.lock(); sent.removeAll(); lock.unlock() }

    func lastBody(matching fragment: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return sent.last { $0.url.contains(fragment) }?.body
    }

    func send(_ request: OutboundRequest) async throws -> OutboundResponse {
        record(request)
        return try await inner.send(request)
    }
    func stream(_ request: OutboundRequest) async throws -> StreamStart {
        record(request)
        var start = try await inner.stream(request)
        lock.lock(); let fragment = watching; lock.unlock()
        guard let fragment, request.url.absoluteString.contains(fragment) else { return start }
        let upstream = start.events
        start.events = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        self.note(event)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Keep cancellation reaching the provider, watcher or not.
            continuation.onTermination = { _ in task.cancel() }
        }
        return start
    }
    func streamRaw(_ request: OutboundRequest) async throws -> RawStreamStart {
        record(request)
        return try await inner.streamRaw(request)
    }
}
