import Foundation
@testable import DerbyCore

func registerEndToEndTests() {

    /// Boots a complete Derby: config file, Keychain-free secret store, SQLite
    /// telemetry, real HTTP listener, mock provider adapter.
    func withDerby(configure: (inout DerbyConfig) -> Void = { _ in },
                   adapter: MockAdapter = MockAdapter(),
                   body: (DerbyEngine, Int, String) async throws -> Void) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        let store = ConfigStore(url: configURL)

        let alpha = Fixture.account("Alpha", models: [Fixture.model("m-a")])
        let beta = Fixture.account("Beta", models: [Fixture.model("m-b")])
        let embedAccount = Fixture.account("Embeddings",
                                           models: [Fixture.model("e-1", caps: [.embeddings])])
        var config = Fixture.config(
            accounts: [alpha, beta, embedAccount],
            logicalModels: [
                Fixture.logical("coding", accounts: [alpha, beta]),
                Fixture.logical("embed", accounts: [embedAccount]),
            ])
        config.gateway = GatewaySettings(port: 0, requireAPIKey: false,
                                         localKeyRef: SecretRef(account: "gw-key"), autoStart: false)
        configure(&config)
        try store.save(config)

        let secrets = InMemorySecretStore()
        let telemetry = TelemetryStore(path: dir.appendingPathComponent("t.sqlite3").path,
                                       settings: config.logging)
        let engine = DerbyEngine(configStore: store, secrets: secrets,
                                 transport: MockTransport(),
                                 adapters: AdapterRegistry(adapters: [.openai: adapter]),
                                 telemetry: telemetry)
        await engine.bootstrap()
        try await engine.startGateway()
        guard case .running(let port, _) = await engine.status else {
            throw TestFailure(message: "gateway did not start: \(await engine.status)",
                              file: #fileID, line: #line)
        }
        let key = await engine.localAPIKey()
        do {
            try await body(engine, port, key)
        } catch {
            await engine.stopGateway()
            throw error
        }
        await engine.stopGateway()
    }

    func post(_ port: Int, _ path: String, _ json: String, key: String? = nil,
              client: String = "Derby-E2E") async throws -> (Int, JSONValue?) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(client, forHTTPHeaderField: "x-derby-client")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        req.httpBody = Data(json.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                JSONValue.parse(String(decoding: data, as: UTF8.self)))
    }

    func get(_ port: Int, _ path: String, key: String? = nil) async throws -> (Int, String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    suite("End to end / OpenAI compatibility") {
        test("a chat completion round-trips through the whole pipeline") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "CAP theorem explained.",
                                        usage: CanonicalUsage(inputTokens: 42, outputTokens: 7)))
            try await withDerby(adapter: adapter) { engine, port, _ in
                let (status, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"Explain CAP theorem."}]}
                """)
                try expectEqual(status, 200)
                let json = try expectNotNil(body)
                try expectEqual(json["object"]?.stringValue, "chat.completion")
                try expectEqual(json["choices"]?[0]?["message"]?["content"]?.stringValue, "CAP theorem explained.")
                try expectEqual(json["choices"]?[0]?["message"]?["role"]?.stringValue, "assistant")
                try expectEqual(json["choices"]?[0]?["finish_reason"]?.stringValue, "stop")
                try expectEqual(json["usage"]?["prompt_tokens"]?.intValue, 42)
                try expectEqual(json["usage"]?["total_tokens"]?.intValue, 49)
                try expectEqual(json["model"]?.stringValue, "m-a", "the physical model is reported back")

                // Derby's own metadata explains the routing decision.
                let derby = try expectNotNil(json["x_derby"])
                try expectEqual(derby["logical_model"]?.stringValue, "coding")
                try expectEqual(derby["provider"]?.stringValue, "Alpha")
                try expectEqual(derby["physical_model"]?.stringValue, "m-a")
                try expect(derby["request_id"]?.stringValue?.hasPrefix("req_") == true)
                try expect(!(derby["routing_reason"]?.stringValue ?? "").isEmpty)
                _ = engine
            }
        }

        test("GET /v1/models advertises logical models owned by derby") {
            try await withDerby { _, port, _ in
                let (status, text) = try await get(port, "/v1/models")
                try expectEqual(status, 200)
                let json = try expectNotNil(JSONValue.parse(text))
                let ids = (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
                try expect(ids.contains("coding"))
                try expect(ids.contains("embed"))
                let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })
                try expectEqual(coding["object"]?.stringValue, "model")
                try expectEqual(coding["owned_by"]?.stringValue, "derby")
                try expectEqual(coding["derby"]?["targets"]?.intValue, 2)
            }
        }

        test("the bare /models path works for clients that omit /v1") {
            try await withDerby { _, port, _ in
                let (status, _) = try await get(port, "/models")
                try expectEqual(status, 200)
            }
        }

        test("streaming produces well-formed OpenAI chunks ending in [DONE]") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "one two three"))
            try await withDerby(adapter: adapter) { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"coding","messages":[{"role":"user","content":"hi"}],"stream":true}
                """.utf8)
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
                try expectContains((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type") ?? "",
                                   "text/event-stream")

                var parser = SSEParser()
                var events: [SSEEvent] = []
                for try await b in bytes { events.append(contentsOf: parser.consume(b)) }

                try expect(events.count >= 3)
                try expect(events.last?.isDone == true, "an OpenAI stream must terminate with [DONE]")
                let chunks = events.compactMap { $0.json }.filter { $0["object"]?.stringValue == "chat.completion.chunk" }
                try expect(!chunks.isEmpty)
                try expectEqual(chunks[0]["choices"]?[0]?["delta"]?["role"]?.stringValue, "assistant")
                let text = chunks.compactMap { $0["choices"]?[0]?["delta"]?["content"]?.stringValue }.joined()
                try expectEqual(text.trimmingCharacters(in: .whitespaces), "one two three")
                try expect(chunks.contains { $0["choices"]?[0]?["finish_reason"]?.stringValue == "stop" })
                try expect(chunks.contains { $0["usage"] != nil }, "usage should be reported on the final chunk")
            }
        }

        test("embeddings return vectors in OpenAI shape") {
            try await withDerby { _, port, _ in
                let (status, body) = try await post(port, "/v1/embeddings", """
                {"model":"embed","input":["hello","world"]}
                """)
                try expectEqual(status, 200)
                let json = try expectNotNil(body)
                try expectEqual(json["object"]?.stringValue, "list")
                try expectEqual(json["data"]?.arrayValue?.count, 2)
                try expectEqual(json["data"]?[0]?["embedding"]?.arrayValue?.count, 3)
                try expectEqual(json["data"]?[1]?["index"]?.intValue, 1)
            }
        }

        test("the Responses API dialect is answered in kind") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "responses answer"))
            try await withDerby(adapter: adapter) { _, port, _ in
                let (status, body) = try await post(port, "/v1/responses", """
                {"model":"coding","input":"hello","instructions":"be terse"}
                """)
                try expectEqual(status, 200)
                let json = try expectNotNil(body)
                try expectEqual(json["object"]?.stringValue, "response")
                try expectEqual(json["status"]?.stringValue, "completed")
                try expectEqual(json["output_text"]?.stringValue, "responses answer")
                try expectEqual(json["output"]?[0]?["type"]?.stringValue, "message")
            }
        }

        test("an unknown model returns 404 and names the models that exist") {
            try await withDerby { _, port, _ in
                let (status, body) = try await post(port, "/v1/chat/completions", """
                {"model":"does-not-exist","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(status, 404)
                let message = try expectNotNil(body?["error"]?["message"]?.stringValue)
                try expectContains(message, "coding")
                try expectEqual(body?["error"]?["derby_failure_kind"]?.stringValue, "MODEL_UNAVAILABLE")
            }
        }

        test("a malformed body returns 400 rather than a crash") {
            try await withDerby { _, port, _ in
                let (status, body) = try await post(port, "/v1/chat/completions", "{not json")
                try expectEqual(status, 400)
                try expect(body?["error"] != nil)
            }
        }
    }

    suite("End to end / failover and history") {
        test("a failing provider is transparently replaced and recorded") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .rateLimit, message: "Rate limited", providerStatus: 429)))
            adapter.set("m-b", .succeed(text: "answered by beta"))
            try await withDerby(adapter: adapter) { engine, port, _ in
                let (status, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(status, 200)
                let json = try expectNotNil(body)
                try expectEqual(json["choices"]?[0]?["message"]?["content"]?.stringValue, "answered by beta")

                let derby = try expectNotNil(json["x_derby"])
                try expectEqual(derby["provider"]?.stringValue, "Beta")
                try expectEqual(derby["failovers"]?.intValue, 1)
                let attempts = try expectNotNil(derby["attempts"]?.arrayValue)
                try expectEqual(attempts.count, 2)
                try expectEqual(attempts[0]["provider"]?.stringValue, "Alpha")
                try expectEqual(attempts[0]["status"]?.stringValue, "failed")
                try expectEqual(attempts[0]["failure"]?.stringValue, "RATE_LIMIT")
                try expectEqual(attempts[1]["status"]?.stringValue, "success")
                try expectContains(try expectNotNil(derby["routing_reason"]?.stringValue), "Failed over")

                // The same story must be inspectable afterwards.
                let requestID = try expectNotNil(derby["request_id"]?.stringValue)
                let history = await engine.telemetry.requests(RequestQuery())
                let record = try expectNotNil(history.first { $0.id == requestID })
                try expectEqual(record.finalProviderName, "Beta")
                try expectEqual(record.attempts.count, 2)
                try expectEqual(record.attempts[0].failureKind, .rateLimit)
                try expectEqual(record.clientName, "Derby-E2E")
                try expect(!record.evaluations.isEmpty, "candidate scores are kept for the inspector")
            }
        }

        test("when everything fails the client gets the mapped status and detail") {
            let adapter = MockAdapter()
            adapter.defaultBehaviour = .fail(DerbyError(kind: .providerDown, message: "everything is down",
                                                        providerStatus: 503))
            try await withDerby(adapter: adapter) { _, port, _ in
                let (status, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(status, 502)
                try expectEqual(body?["error"]?["derby_failure_kind"]?.stringValue, "PROVIDER_DOWN")
            }
        }

        test("repeated failures open a circuit, which the health endpoint reports") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .providerDown, message: "down", providerStatus: 503)))
            adapter.set("m-b", .succeed(text: "beta"))
            try await withDerby(adapter: adapter) { engine, port, _ in
                for _ in 0..<4 {
                    _ = try await post(port, "/v1/chat/completions", """
                    {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                    """)
                }
                let config = await engine.config()
                let alphaID = try expectNotNil(config.providers.first { $0.name == "Alpha" }?.id)
                let health = await engine.healthRegistry.health(for: TargetKey(providerID: alphaID, modelID: "m-a"))
                try expectEqual(health.circuit, .open, "a persistently failing target must be taken out of rotation")

                let (status, text) = try await get(port, "/health")
                try expectEqual(status, 200)
                try expectContains(text, "\"open_circuits\"")

                // With Alpha's circuit open, the next request skips it entirely.
                adapter.resetCounts()
                let (code, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(code, 200)
                try expectEqual(body?["x_derby"]?["provider"]?.stringValue, "Beta")
                try expectEqual(adapter.calls("m-a"), 0, "an open circuit must be filtered before dispatch")
            }
        }
    }

    suite("End to end / gateway behaviour") {
        test("the local API key is enforced when enabled") {
            try await withDerby(configure: { $0.gateway.requireAPIKey = true }) { _, port, key in
                try expect(!key.isEmpty, "Derby must generate a local key on first run")
                let (unauthorized, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[]}
                """)
                try expectEqual(unauthorized, 401)
                try expectContains(try expectNotNil(body?["error"]?["message"]?.stringValue), "API key")

                let (wrong, _) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[]}
                """, key: "derby-wrong-key")
                try expectEqual(wrong, 401)

                let (ok, _) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """, key: key)
                try expectEqual(ok, 200)

                // Liveness stays reachable without a key so supervisors can poll it.
                let (health, _) = try await get(port, "/health")
                try expectEqual(health, 200)
            }
        }

        test("a required key that cannot be loaded refuses traffic instead of serving it") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-nokey-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
            let account = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            var config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("coding", accounts: [account])])
            config.gateway = GatewaySettings(port: 0, requireAPIKey: true,
                                             localKeyRef: SecretRef(account: "gw-key"), autoStart: false)
            try store.save(config)

            // Stands in for a Keychain that cannot be read or written.
            let engine = DerbyEngine(configStore: store, secrets: UnavailableSecretStore(),
                                     transport: MockTransport(),
                                     adapters: AdapterRegistry(adapters: [.openai: MockAdapter()]),
                                     telemetry: TelemetryStore(path: dir.appendingPathComponent("t.sqlite3").path))
            await engine.bootstrap()
            try await engine.startGateway()
            let warnings = await engine.startupWarnings
            try expect(warnings.contains { $0.contains("Keychain") },
                       "the user must be told why the gateway is refusing requests")
            guard case .running(let port, _) = await engine.status else {
                throw TestFailure(message: "gateway did not start", file: #fileID, line: #line)
            }
            let (status, body) = try await post(port, "/v1/chat/completions", """
            {"model":"coding","messages":[{"role":"user","content":"hi"}]}
            """)
            try expectEqual(status, 401, "an unreadable key must fail closed, never open")
            try expectContains(try expectNotNil(body?["error"]?["message"]?.stringValue), "Keychain")
            await engine.stopGateway()
        }

        test("metrics are exposed in Prometheus text format") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "ok"))
            try await withDerby(adapter: adapter) { _, port, _ in
                _ = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                let (status, text) = try await get(port, "/metrics")
                try expectEqual(status, 200)
                try expectContains(text, "# TYPE derby_requests_total counter")
                try expectContains(text, "derby_target_success_rate")
                try expectContains(text, "provider=\"Alpha\"")
            }
        }

        test("the root page documents the endpoint") {
            try await withDerby { _, port, _ in
                let (status, text) = try await get(port, "/")
                try expectEqual(status, 200)
                try expectContains(text, "/v1/chat/completions")
            }
        }

        test("CORS preflight is answered for browser clients") {
            try await withDerby { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "OPTIONS"
                req.setValue("http://localhost:3000", forHTTPHeaderField: "origin")
                let (_, response) = try await URLSession.shared.data(for: req)
                let http = response as? HTTPURLResponse
                try expectEqual(http?.statusCode, 204)
                try expectEqual(http?.value(forHTTPHeaderField: "access-control-allow-origin"), "http://localhost:3000")
            }
        }

        test("routing can be paused and resumed without stopping the gateway") {
            try await withDerby { engine, port, _ in
                await engine.setRoutingPaused(true)
                let (paused, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(paused, 503)
                try expectContains(try expectNotNil(body?["error"]?["message"]?.stringValue), "paused")

                await engine.setRoutingPaused(false)
                let (resumed, _) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(resumed, 200)
            }
        }

        test("configuration changes take effect without a restart") {
            try await withDerby { engine, port, _ in
                _ = await engine.update { config in
                    var lm = Fixture.logical("brand-new", accounts: [config.providers[0]])
                    lm.summary = "added at runtime"
                    config.logicalModels.append(lm)
                }
                let (status, text) = try await get(port, "/v1/models")
                try expectEqual(status, 200)
                try expectContains(text, "brand-new")

                let (code, _) = try await post(port, "/v1/chat/completions", """
                {"model":"brand-new","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(code, 200)
            }
        }

        test("configuration survives a full engine restart") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-restart-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let configURL = dir.appendingPathComponent("config.json")
            let dbPath = dir.appendingPathComponent("t.sqlite3").path
            let secrets = InMemorySecretStore()

            let first = DerbyEngine(configStore: ConfigStore(url: configURL), secrets: secrets,
                                    transport: MockTransport(),
                                    adapters: AdapterRegistry(adapters: [.openai: MockAdapter()]),
                                    telemetry: TelemetryStore(path: dbPath))
            await first.bootstrap()
            _ = await first.update { config in
                config.gateway.autoStart = false
                config.gateway.port = 8899
                config.logicalModels.append(LogicalModel(name: "persisted",
                                                          summary: "should still be here",
                                                          policy: RoutingPolicy(strategy: .lowestCost)))
            }
            let originalKey = await first.localAPIKey()
            await first.stopGateway()

            let second = DerbyEngine(configStore: ConfigStore(url: configURL), secrets: secrets,
                                     transport: MockTransport(),
                                     adapters: AdapterRegistry(adapters: [.openai: MockAdapter()]),
                                     telemetry: TelemetryStore(path: dbPath))
            await second.bootstrap()
            let config = await second.config()
            try expectEqual(config.gateway.port, 8899)
            let lm = try expectNotNil(config.logicalModel(named: "persisted"))
            try expectEqual(lm.policy.strategy, .lowestCost)
            try expectEqual(lm.summary, "should still be here")
            try expectEqual(await second.localAPIKey(), originalKey, "the local key must be stable across launches")
            await second.stopGateway()
        }
    }

    suite("End to end / simulator and console") {
        test("the simulator explains a decision without sending a request") {
            let adapter = MockAdapter()
            try await withDerby(adapter: adapter) { engine, _, _ in
                var input = DerbyEngine.SimulationInput(logicalModel: "coding")
                input.needsTools = true
                input.contextTokens = 40_000
                let result = await engine.simulate(input)
                switch result {
                case .failure(let e):
                    throw TestFailure(message: "simulation failed: \(e.message)", file: #fileID, line: #line)
                case .success(let decision):
                    try expectEqual(decision.plan.attempts.count, 2)
                    try expect(!decision.explanation.isEmpty)
                    try expectContains(decision.trace, "Requested logical model: coding")
                }
                try expectEqual(adapter.totalCalls, 0, "simulation must not call any provider")
            }
        }

        test("the simulator reports exclusions for impossible requests") {
            try await withDerby { engine, _, _ in
                var input = DerbyEngine.SimulationInput(logicalModel: "coding")
                input.needsVision = true
                let result = await engine.simulate(input)
                if case .success = result {
                    throw TestFailure(message: "expected no vision-capable target", file: #fileID, line: #line)
                }
            }
        }

        test("the test console runs the same pipeline and returns a record") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "console reply"))
            try await withDerby(adapter: adapter) { engine, _, _ in
                let collected = TextBox()
                let result = await engine.runConsole(logicalModel: "coding", prompt: "hi",
                                                     systemPrompt: nil, stream: true) { event in
                    if case .textDelta(let t) = event { collected.append(t) }
                }
                switch result {
                case .failure(let e):
                    throw TestFailure(message: "console failed: \(e.message)", file: #fileID, line: #line)
                case .success(let record):
                    try expectEqual(record.clientName, "Derby Console")
                    try expect(record.succeeded)
                    try expectEqual(record.finalProviderName, "Alpha")
                }
                try expectEqual(collected.text.trimmingCharacters(in: .whitespaces), "console reply")
            }
        }
    }
}

/// Thread-safe accumulator for streamed console text.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) { lock.lock(); value += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}
