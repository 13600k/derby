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
                try expectEqual(coding["derby"]?["target_count"]?.intValue, 2)
                // A client that only ever asks for "coding" still learns what it resolves to.
                try expectEqual(coding["derby"]?["active_model"]?["id"]?.stringValue, "m-a")
                try expectEqual(coding["derby"]?["active_model"]?["provider"]?.stringValue, "Alpha")
                try expectEqual(coding["context_window"]?.intValue, 128_000)
                try expectEqual(coding["derby"]?["targets"]?.arrayValue?.count, 2)
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
        test("a client needs nothing but the port") {
            // The default gateway: no Authorization header at all, and the
            // arbitrary key an OpenAI SDK insists on sending is ignored.
            try await withDerby { _, port, _ in
                let (open, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(open, 200)
                try expectNotNil(body?["choices"])

                let (ignored, _) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """, key: "whatever-the-client-had-lying-around")
                try expectEqual(ignored, 200)

                let (models, _) = try await get(port, "/v1/models")
                try expectEqual(models, 200)
                let (landing, text) = try await get(port, "/")
                try expectEqual(landing, 200)
                try expectContains(text, "Authentication: none")
            }
        }

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

    suite("End to end / runtime model visibility") {
        test("the response reports the physical model and describes it in x_derby") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "hi"))
            try await withDerby(adapter: adapter) { _, port, _ in
                let (status, body) = try await post(port, "/v1/chat/completions", """
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """)
                try expectEqual(status, 200)
                let json = try expectNotNil(body)
                try expectEqual(json["model"]?.stringValue, "m-a", "never the alias the client asked for")
                let model = try expectNotNil(json["x_derby"]?["model"])
                try expectEqual(model["id"]?.stringValue, "m-a")
                try expectEqual(model["provider"]?.stringValue, "Alpha")
                try expectEqual(model["context_window"]?.intValue, 128_000)
                try expectEqual(model["max_output_tokens"]?.intValue, 8192)
                try expect((model["capabilities"]?.arrayValue ?? []).contains(.string("streaming")))
            }
        }

        test("runtime metadata is also on the response headers") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "hi"))
            try await withDerby(adapter: adapter) { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"coding","messages":[{"role":"user","content":"hi"}]}
                """.utf8)
                let (_, response) = try await URLSession.shared.data(for: req)
                let http = try expectNotNil(response as? HTTPURLResponse)
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-model"), "m-a")
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-logical-model"), "coding")
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-provider"), "Alpha")
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-context-window"), "128000")
                try expectContains(http.value(forHTTPHeaderField: "x-derby-capabilities") ?? "", "tools")
            }
        }

        test("a stream announces its model before the first token, not after the last") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)))
            adapter.set("m-b", .succeed(text: "beta streamed this"))
            try await withDerby(adapter: adapter) { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"coding","messages":[{"role":"user","content":"hi"}],"stream":true}
                """.utf8)
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                var parser = SSEParser()
                var events: [SSEEvent] = []
                for try await b in bytes { events.append(contentsOf: parser.consume(b)) }
                let chunks = events.compactMap { $0.json }.filter { $0["object"]?.stringValue == "chat.completion.chunk" }

                // The very first chunk names the model that failed over to, and describes it.
                let first = try expectNotNil(chunks.first)
                try expectEqual(first["model"]?.stringValue, "m-b")
                let route = try expectNotNil(first["x_derby"])
                try expectEqual(route["physical_model"]?.stringValue, "m-b")
                try expectEqual(route["model"]?["provider"]?.stringValue, "Beta")
                try expectEqual(route["model"]?["context_window"]?.intValue, 128_000)
                try expectEqual(route["attempt"]?.stringValue, "attempt_2",
                                "the metadata belongs to the attempt that is actually producing")

                // ...and the tail chunk still carries the full record.
                let tail = try expectNotNil(chunks.last { $0["x_derby"] != nil && $0["choices"]?.arrayValue?.isEmpty == true })
                try expectEqual(tail["x_derby"]?["physical_model"]?.stringValue, "m-b")
                try expectEqual(tail["x_derby"]?["failovers"]?.intValue, 1)
            }
        }

        test("a failover before the first token corrects what the client was told") {
            let adapter = MockAdapter()
            adapter.set("m-a", .openThenFail(DerbyError(kind: .transient, message: "dropped", providerStatus: 500)))
            adapter.set("m-b", .succeed(text: "beta finished it"))
            try await withDerby(adapter: adapter) { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"coding","messages":[{"role":"user","content":"hi"}],"stream":true}
                """.utf8)
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                var parser = SSEParser()
                var events: [SSEEvent] = []
                for try await b in bytes { events.append(contentsOf: parser.consume(b)) }
                let chunks = events.compactMap { $0.json }.filter { $0["object"]?.stringValue == "chat.completion.chunk" }

                // Announced as Alpha, because Alpha's stream really did open...
                let announcements = chunks.compactMap { $0["x_derby"] }
                    .compactMap { $0["physical_model"]?.stringValue }
                try expectEqual(announcements.first, "m-a")
                // ...then corrected the moment Derby moved to Beta, before any content.
                try expect(announcements.contains("m-b"),
                           "a transparent failover must be re-announced, not left stale")
                let text = chunks.compactMap { $0["choices"]?[0]?["delta"]?["content"]?.stringValue }.joined()
                try expectEqual(text.trimmingCharacters(in: .whitespaces), "beta finished it")
                // Every chunk that carried content came from the model finally named.
                try expectEqual(chunks.last?["x_derby"]?["physical_model"]?.stringValue, "m-b")
            }
        }

        test("a streaming response carries the planned target on its headers") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "streamed"))
            try await withDerby(adapter: adapter) { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"coding","messages":[{"role":"user","content":"hi"}],"stream":true}
                """.utf8)
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                let http = try expectNotNil(response as? HTTPURLResponse)
                // Headers are flushed before any target runs, so they are the plan,
                // named as such; the first chunk carries the authoritative answer.
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-planned-model"), "m-a")
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-planned-context-window"), "128000")
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-logical-model"), "coding")
                for try await _ in bytes {}
            }
        }

        test("a streamed Responses call carries the runtime model on response.created") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "streamed"))
            try await withDerby(adapter: adapter) { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"coding","input":"hi","stream":true}
                """.utf8)
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                var parser = SSEParser()
                var events: [SSEEvent] = []
                for try await b in bytes { events.append(contentsOf: parser.consume(b)) }
                let created = try expectNotNil(events.compactMap { $0.json }
                    .first { $0["type"]?.stringValue == "response.created" })
                try expectEqual(created["response"]?["model"]?.stringValue, "m-a")
                try expectEqual(created["response"]?["x_derby"]?["model"]?["id"]?.stringValue, "m-a")
                try expectEqual(created["response"]?["x_derby"]?["model"]?["context_window"]?.intValue, 128_000)
            }
        }

        test("embeddings report the model that ran too") {
            try await withDerby { _, port, _ in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/embeddings")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data("""
                {"model":"embed","input":["hello"]}
                """.utf8)
                let (data, response) = try await URLSession.shared.data(for: req)
                let http = try expectNotNil(response as? HTTPURLResponse)
                try expectEqual(http.value(forHTTPHeaderField: "x-derby-model"), "e-1")
                let json = try expectNotNil(JSONValue.parse(String(decoding: data, as: UTF8.self)))
                try expectEqual(json["model"]?.stringValue, "e-1")
                try expectEqual(json["x_derby"]?["model"]?["id"]?.stringValue, "e-1")
                try expect((json["x_derby"]?["model"]?["capabilities"]?.arrayValue ?? [])
                            .contains(.string("embeddings")))
            }
        }
    }

    suite("End to end / context compaction") {
        test("an oversized conversation is shortened, answered, and disclosed over HTTP") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "Answered from a shortened conversation.",
                                        usage: CanonicalUsage(inputTokens: 5_000, outputTokens: 8)))
            try await withDerby(configure: { config in
                // One target, deliberately far too small for what the client sends.
                let small = Fixture.account("Alpha", models: [Fixture.model("m-a", context: 16_000)])
                var lm = Fixture.logical("coding", accounts: [small])
                lm.compaction = CompactionPolicy(enabled: true, strategy: .dropOldest,
                                                 keepRecentMessages: 4)
                config.providers = [small]
                config.logicalModels = [lm]
            }, adapter: adapter) { _, port, _ in
                // ~100k tokens of conversation against a 16k window.
                var messages: [String] = []
                for i in 0..<50 {
                    let filler = String(repeating: "x", count: 4_000)
                    messages.append("{\"role\":\"user\",\"content\":\"\(filler) turn \(i)\"}")
                    messages.append("{\"role\":\"assistant\",\"content\":\"\(filler) reply \(i)\"}")
                }
                messages.append("{\"role\":\"user\",\"content\":\"What was the final decision?\"}")
                let payload = "{\"model\":\"coding\",\"messages\":[\(messages.joined(separator: ","))]}"

                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = Data(payload.utf8)
                let (data, response) = try await URLSession.shared.data(for: req)
                let http = try expectNotNil(response as? HTTPURLResponse)
                try expectEqual(http.statusCode, 200, String(decoding: data, as: UTF8.self))

                // The header a body-blind client would read.
                let header = try expectNotNil(http.value(forHTTPHeaderField: "x-derby-compacted"))
                try expectContains(header, "drop_oldest")

                let json = try expectNotNil(JSONValue.parse(String(decoding: data, as: UTF8.self)))
                let c = try expectNotNil(json["x_derby"]?["compaction"])
                try expectEqual(c["applied"]?.boolValue, true)
                try expectEqual(c["strategy"]?.stringValue, "drop_oldest")
                try expectEqual(c["context_limit_tokens"]?.intValue, 16_000)
                try expect((c["dropped_messages"]?.intValue ?? 0) > 50)
                try expect((c["compacted_prompt_tokens"]?.intValue ?? .max) <= 16_000)

                // The provider really was handed the shortened conversation, and
                // the client's last question survived it.
                let sent = try expectNotNil(adapter.lastRequest("m-a"))
                try expect(sent.messages.count < 101)
                try expectEqual(sent.messages.last?.joinedText, "What was the final decision?")
            }
        }

        test("with compaction off the same request is refused as too long, not truncated") {
            try await withDerby(configure: { config in
                let small = Fixture.account("Alpha", models: [Fixture.model("m-a", context: 16_000)])
                config.providers = [small]
                config.logicalModels = [Fixture.logical("coding", accounts: [small])]
            }) { _, port, _ in
                var messages: [String] = []
                for i in 0..<50 {
                    let filler = String(repeating: "x", count: 4_000)
                    messages.append("{\"role\":\"user\",\"content\":\"\(filler) turn \(i)\"}")
                }
                let payload = "{\"model\":\"coding\",\"messages\":[\(messages.joined(separator: ","))]}"
                let (status, body) = try await post(port, "/v1/chat/completions", payload)
                // 400, not 503: the client sent more than any target can hold,
                // which is a problem with the request, not with a provider.
                try expectEqual(status, 400)
                let message = body?["error"]?["message"]?.stringValue ?? ""
                try expectContains(message, "context window too small")
                try expectContains(message, "Enable compaction")
                try expectEqual(body?["error"]?["code"]?.stringValue, "context_overflow")
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
