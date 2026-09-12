import Foundation
@testable import DerbyCore

/// Spreading work by how busy each target already is, preferring a copy of a
/// model that is already in memory, and learning what local servers have loaded.
func registerLoadTests() {

    func account(_ name: String, kind: ProviderKind = .openAICompatible, model: String,
                 capacity: Int = 8) -> ProviderAccount {
        Fixture.account(name, kind: kind, models: [Fixture.model(model)], maxConcurrent: capacity)
    }

    func config(_ accounts: [ProviderAccount], strategy: RoutingStrategyKind,
                weights: ScoreWeights = .balanced, preferWarm: Bool? = nil) -> DerbyConfig {
        var lm = Fixture.logical("x", accounts: accounts, strategy: strategy, weights: weights)
        lm.policy.preferWarmModels = preferWarm
        return Fixture.config(accounts: accounts, logicalModels: [lm])
    }

    func route(_ config: DerbyConfig, load: [UUID: HealthRegistry.AccountLoad] = [:],
               residency: [UUID: AccountResidency] = [:], lineage: ModelLineage? = nil) throws -> RoutingDecision {
        var snapshot = Fixture.snapshot(config)
        snapshot.accountLoad = load
        snapshot.residency = residency
        return try Router().route(RoutingRequest(logicalModelName: "x",
                                                 requirements: CapabilityRequirements(required: [.text]),
                                                 promptTokens: 100, conversationLineage: lineage),
                                  snapshot: snapshot)
    }

    func order(_ decision: RoutingDecision) -> [String] { decision.plan.attempts.map(\.target.providerName) }

    /// Weights that consider a single dimension.
    func only(_ dimension: WritableKeyPath<ScoreWeights, Double>) -> ScoreWeights {
        var weights = ScoreWeights(quality: 0, latency: 0, cost: 0, health: 0, quota: 0, priority: 0)
        weights[keyPath: dimension] = 1
        return weights
    }

    // MARK: - Ranking

    suite("Load / least loaded") {
        test("accounts are compared by how full they are, not by raw counts") {
            let local = account("Local", kind: .ollama, model: "qwen3:8b", capacity: 2)
            let hosted = account("Hosted", model: "gpt-5-mini", capacity: 40)
            // One of two slots is fuller than ten of forty.
            let decision = try route(config([local, hosted], strategy: .leastLoaded),
                                     load: [local.id: .init(inFlight: 1), hosted.id: .init(inFlight: 10)])
            try expectEqual(order(decision), ["Hosted", "Local"])
            try expectContains(decision.explanation, "spare capacity")
        }

        test("requests routed but not yet started count against a target") {
            let a = account("A", model: "m-a"), b = account("B", model: "m-b")
            try expectEqual(order(try route(config([a, b], strategy: .leastLoaded), load: [a.id: .init(reserved: 1)])),
                            ["B", "A"])
        }

        test("equal load goes to a model already in memory, then to the configured order") {
            let first = account("First", kind: .ollama, model: "qwen3:8b")
            let second = account("Second", kind: .ollama, model: "llama3.2:3b")
            let c = config([first, second], strategy: .leastLoaded)
            try expectEqual(order(try route(c)), ["First", "Second"])
            let reports = [first.id: AccountResidency(loadedModels: []),
                           second.id: AccountResidency(loadedModels: ["llama3.2:3b"])]
            try expectEqual(order(try route(c, residency: reports)), ["Second", "First"])
        }

        test("a weighted score can weigh spare capacity alongside everything else") {
            let a = account("A", model: "m-a"), b = account("B", model: "m-b")
            let c = config([a, b], strategy: .weightedScore, weights: only(\.load))
            try expectEqual(order(try route(c, load: [a.id: .init(inFlight: 6)])), ["B", "A"])
            try expect(c.logicalModels[0].policy.readsLoad, "ranking on load needs a reservation")
            try expect(!RoutingPolicy(strategy: .weightedScore).readsLoad, "a score that ignores load does not")
        }
    }

    // MARK: - Reservations

    suite("Load / reservations") {
        test("a reservation counts until its request starts, then becomes that request") {
            let health = HealthRegistry()
            let accountID = UUID()
            let key = TargetKey(providerID: accountID, modelID: "m")
            let reservation = try expectNotNil(await health.reserve(key, accountID: accountID))
            try expectEqual(await health.accountLoad()[accountID], HealthRegistry.AccountLoad(inFlight: 0, reserved: 1))

            let before = await health.snapshotWithLoad().loadVersion
            await health.acquire(key, accountID: accountID, converting: reservation)
            try expectEqual(await health.accountLoad()[accountID], HealthRegistry.AccountLoad(inFlight: 1, reserved: 0))
            try expectEqual(await health.snapshotWithLoad().loadVersion, before,
                            "the total did not change, so nobody else's claim should fail")

            await health.release(reservation)
            try expectEqual(await health.accountLoad()[accountID]?.inFlight, 1,
                            "a reservation that became a request has nothing left to give back")
            await health.release(key, accountID: accountID)
            try expectNil(await health.accountLoad()[accountID])
        }

        test("a claim made on counts that have since moved is refused, so the caller routes again") {
            let health = HealthRegistry()
            let accountID = UUID()
            let a = TargetKey(providerID: accountID, modelID: "a"), b = TargetKey(providerID: accountID, modelID: "b")
            let read = await health.snapshotWithLoad().loadVersion
            _ = try expectNotNil(await health.reserve(a, accountID: accountID, ifLoadVersion: read))
            try expectNil(await health.reserve(b, accountID: accountID, ifLoadVersion: read),
                          "another request claimed a slot after these counts were read")
            let fresh = await health.snapshotWithLoad().loadVersion
            _ = try expectNotNil(await health.reserve(b, accountID: accountID, ifLoadVersion: fresh))
            try expectEqual(await health.accountLoad()[accountID]?.reserved, 2)
        }

        /// One target, its own health registry, and a reservation for it.
        func reserved() async throws -> (HealthRegistry, MockAdapter, Executor, RoutingDecision, UUID) {
            let target = Fixture.account("A", models: [Fixture.model("m-a")])
            let c = Fixture.config(accounts: [target], logicalModels: [Fixture.logical("x", accounts: [target])])
            let health = HealthRegistry(settings: c.health)
            let adapter = MockAdapter()
            return (health, adapter, Fixture.executor(adapter: adapter, health: health),
                    try Fixture.decision(c, model: "x"), target.id)
        }

        test("the executor gives a reservation back when its request is answered") {
            let (health, adapter, executor, decision, accountID) = try await reserved()
            adapter.set("m-a", .succeed(text: "ok"))
            let reservation = await health.reserve(decision.plan.attempts[0].target.key, accountID: accountID)
            _ = try await executor.execute(CanonicalRequest(requestedModel: "x", messages: [.user("hi")]),
                                           decision: decision, meta: RequestMeta(loadReservation: reservation))
            try expectNil(await health.accountLoad()[accountID])
        }

        test("the executor gives a reservation back when its request fails") {
            let (health, adapter, executor, decision, accountID) = try await reserved()
            adapter.set("m-a", .fail(DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)))
            let reservation = await health.reserve(decision.plan.attempts[0].target.key, accountID: accountID)
            _ = try? await executor.execute(CanonicalRequest(requestedModel: "x", messages: [.user("hi")]),
                                            decision: decision, meta: RequestMeta(loadReservation: reservation))
            try expectNil(await health.accountLoad()[accountID])
        }

        test("a stream gives back a reservation for a target it never reached") {
            let (health, adapter, executor, decision, accountID) = try await reserved()
            adapter.set("m-a", .succeed(text: "ok"))
            let elsewhere = await health.reserve(TargetKey(providerID: accountID, modelID: "other"), accountID: accountID)
            var request = CanonicalRequest(requestedModel: "x", messages: [.user("hi")])
            request.stream = true
            for try await _ in executor.stream(request, decision: decision, meta: RequestMeta(loadReservation: elsewhere)) {}
            try await eventually("the stream's reservation is released") {
                await health.accountLoad()[accountID] == nil
            }
        }
    }

    // MARK: - Warm copies

    suite("Load / warm copies") {
        /// The same weights on two servers: interchangeable answers, different waits.
        func copies() -> (ProviderAccount, ProviderAccount) {
            (account("Box A", kind: .ollama, model: "qwen3.6:27b-q4_K_M"),
             account("Box B", kind: .vllm, model: "Qwen/Qwen3.6-27B-FP8"))
        }

        test("a loaded copy of the same model goes ahead of one that would have to load") {
            let (a, b) = copies()
            let reports = [a.id: AccountResidency(loadedModels: ["llama3.2:3b"]),
                           b.id: AccountResidency(loadedModels: ["Qwen/Qwen3.6-27B-FP8"])]
            let decision = try route(config([a, b], strategy: .weightedScore), residency: reports)
            try expectEqual(order(decision), ["Box B", "Box A"])
            try expectContains(decision.explanation, "already loaded")
        }

        test("a different model is never promoted just for being loaded") {
            let qwen = account("Qwen box", kind: .ollama, model: "qwen3.6:27b")
            let llama = account("Llama box", kind: .ollama, model: "llama3.3:70b")
            let reports = [qwen.id: AccountResidency(loadedModels: []),
                           llama.id: AccountResidency(loadedModels: ["llama3.3:70b"])]
            try expectEqual(order(try route(config([qwen, llama], strategy: .weightedScore), residency: reports)),
                            ["Qwen box", "Llama box"], "which model answers is the strategy's decision")
        }

        test("a configured order stays the instruction unless warm copies are asked for") {
            let (a, b) = copies()
            let reports = [a.id: AccountResidency(loadedModels: []),
                           b.id: AccountResidency(loadedModels: ["Qwen/Qwen3.6-27B-FP8"])]
            try expectEqual(order(try route(config([a, b], strategy: .priority), residency: reports)),
                            ["Box A", "Box B"])
            try expectEqual(order(try route(config([a, b], strategy: .priority, preferWarm: true), residency: reports)),
                            ["Box B", "Box A"])
        }

        test("only a fresh report is trusted, and a hosted model is always ready") {
            let (a, _) = copies()
            let hosted = account("Hosted", model: "gpt-5.1")
            var snapshot = Fixture.snapshot(config([a, hosted], strategy: .priority))
            let targets = try expectNotNil(snapshot.logicalModel(named: "x")?.targets)
            snapshot.residency[a.id] = AccountResidency(loadedModels: ["qwen3.6:27b-q4_K_M"])
            try expectEqual(snapshot.warmth(for: targets[0]), .loaded)
            snapshot.residency[a.id] = AccountResidency(loadedModels: ["qwen3.6:27b-q4_K_M"],
                                                        observedAt: Date().addingTimeInterval(-120))
            try expectEqual(snapshot.warmth(for: targets[0]), .unknown, "two minutes old is too old to trust")
            try expectEqual(snapshot.warmth(for: targets[1]), .alwaysAvailable)
            try expect(AccountResidency(loadedModels: ["qwen3"]).contains("qwen3:latest"), "Ollama's implicit tag")
        }
    }

    // MARK: - Continuity

    suite("Load / continuity") {
        test("continuity favours the model family that wrote the conversation so far") {
            let gpt = account("GPT", model: "gpt-5.1")
            let qwen = account("Qwen", kind: .ollama, model: "qwen3.6:27b")
            let c = config([gpt, qwen], strategy: .weightedScore, weights: only(\.continuity))
            try expectEqual(order(try route(c, lineage: .parse("Qwen/Qwen3.6-27B-FP8"))), ["Qwen", "GPT"])
            try expectEqual(order(try route(c, lineage: .parse("gpt-5.1-codex"))), ["GPT", "Qwen"])
        }

        test("a request learns whose conversation it continues from its history") {
            let request = CanonicalRequest(requestedModel: "x", messages: [
                .user("q"),
                CanonicalMessage(role: .assistant, content: [.text("a")],
                                 origin: MessageOrigin(modelID: "qwen3.6:27b", providerKind: "ollama", accountID: nil)),
                .user("next"),
            ])
            try expectEqual(RoutingRequest(request).conversationLineage?.identity,
                            ModelLineage.parse("qwen3.6:27b").identity)
            try expectNil(RoutingRequest(CanonicalRequest(requestedModel: "x", messages: [.user("q")])).conversationLineage)
        }
    }

    // MARK: - Residency

    suite("Load / residency") {
        func context(_ kind: ProviderKind, _ base: String, _ transport: MockTransport) -> ProviderContext {
            var server = Fixture.account("Server", kind: kind, models: [])
            server.baseURLOverride = base
            return ProviderContext(account: server, transport: transport, secrets: InMemorySecretStore(),
                                   credentials: CredentialCache())
        }

        test("Ollama reports the models it is running") {
            let transport = MockTransport()
            transport.stub("/api/ps", json: """
            {"models":[{"name":"qwen3.6:27b","model":"qwen3.6:27b","size_vram":17000000000,
                        "expires_at":"2026-09-11T12:05:00Z"}]}
            """)
            let loaded = try await OpenAIAdapter().loadedModels(context(.ollama, "http://127.0.0.1:11434/v1", transport))
            try expectEqual(loaded, ["qwen3.6:27b"])
        }

        test("LM Studio counts only models with a loaded instance") {
            let transport = MockTransport()
            transport.stub("/api/v1/models", json: """
            {"models":[{"key":"qwen/qwen3-8b","loaded_instances":[{"id":"qwen/qwen3-8b"}]},
                       {"key":"google/gemma-3-12b","loaded_instances":[]}]}
            """)
            let loaded = try await OpenAIAdapter().loadedModels(context(.lmStudio, "http://127.0.0.1:1234/v1", transport))
            try expectEqual(loaded, ["qwen/qwen3-8b"])
        }

        test("vLLM serves only what it has loaded; llama.cpp's router mode says which") {
            let vllm = MockTransport()
            vllm.stub("/models", json: #"{"data":[{"id":"Qwen/Qwen3.6-27B-FP8","object":"model"}]}"#)
            try expectEqual(try await OpenAIAdapter().loadedModels(context(.vllm, "http://127.0.0.1:8000/v1", vllm)),
                            ["Qwen/Qwen3.6-27B-FP8"])
            let llama = MockTransport()
            llama.stub("/models", json: #"{"data":[{"id":"a","status":{"value":"loaded"}},{"id":"b","status":{"value":"unloaded"}}]}"#)
            try expectEqual(try await OpenAIAdapter().loadedModels(context(.llamaCpp, "http://127.0.0.1:8080/v1", llama)),
                            ["a"])
        }

        test("hosted APIs are not asked") {
            let transport = MockTransport()
            try expectNil(try await OpenAIAdapter().loadedModels(context(.openai, "https://api.openai.com/v1", transport)))
            try expectEqual(transport.requests.count, 0)
        }

        test("the poller records each server's report and stops trusting one that does not answer") {
            let transport = MockTransport()
            transport.stub("/api/ps", json: #"{"models":[{"name":"llama3.2:3b","model":"llama3.2:3b"}]}"#)
            transport.stub("/api/v1/models", status: 500, json: "{}")
            var ollama = Fixture.account("Ollama", kind: .ollama, models: [])
            ollama.baseURLOverride = "http://127.0.0.1:11434/v1"
            var lmStudio = Fixture.account("LM Studio", kind: .lmStudio, models: [])
            lmStudio.baseURLOverride = "http://127.0.0.1:1234/v1"
            let registry = ResidencyRegistry()
            await registry.update(accountID: lmStudio.id, loadedModels: ["from-an-earlier-poll"])
            await DerbyEngine.pollResidency(config: Fixture.config(accounts: [ollama, lmStudio], logicalModels: []),
                                            adapters: AdapterRegistry(), transport: transport,
                                            secrets: InMemorySecretStore(), credentials: CredentialCache(),
                                            into: registry)
            let reports = await registry.snapshot()
            try expect(reports[ollama.id]?.contains("llama3.2:3b") == true)
            try expectNil(reports[lmStudio.id], "a report that can no longer be confirmed is dropped")
        }
    }

    // MARK: - What the server says about itself

    suite("Load / occupancy") {
        func server(_ kind: ProviderKind, _ base: String, _ transport: MockTransport) -> ProviderContext {
            var account = Fixture.account("Server", kind: kind, models: [])
            account.baseURLOverride = base
            return ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                                   credentials: CredentialCache())
        }

        test("a metrics page is read per gauge, ignoring labels and comments") {
            let samples = PrometheusText.samples("""
            # HELP vllm:num_requests_running Number of requests currently running on GPU.
            # TYPE vllm:num_requests_running gauge
            vllm:num_requests_running{model_name="Qwen3.8-27B-FP8"} 3.0
            vllm:num_requests_running{model_name="other"} 1.0
            vllm:num_requests_waiting{model_name="Qwen3.8-27B-FP8"} 2.0
            vllm:gpu_cache_usage_perc{model_name="Qwen3.8-27B-FP8"} 0.42

            """)
            try expectEqual(PrometheusText.total(samples, "vllm:num_requests_running"), 4,
                            "requests add up across the models a server hosts")
            try expectEqual(PrometheusText.peak(samples, "vllm:gpu_cache_usage_perc"), 0.42,
                            "a ratio does not")
            try expectNil(PrometheusText.total(samples, "vllm:not_published"))
        }

        test("vLLM reports what it is running, what is waiting, and how full its cache is") {
            let transport = MockTransport()
            transport.stub("/metrics", json: """
            vllm:num_requests_running{engine="0",model_name="m"} 3.0
            vllm:num_requests_waiting{engine="0",model_name="m"} 2.0
            vllm:num_requests_waiting_by_reason{engine="0",model_name="m",reason="capacity"} 2.0
            vllm:kv_cache_usage_perc{engine="0",model_name="m"} 0.42
            """)
            let busy = try expectNotNil(try await OpenAIAdapter()
                .occupancy(server(.vllm, "http://gpu-box:8000/v1", transport)))
            try expectEqual(busy.running, 3)
            try expectEqual(busy.queued, 2, "the by-reason breakdown is a different gauge, not more waiting requests")
            try expectEqual(busy.kvCacheUsage, 0.42)
            try expect(busy.isSaturated, "work is already queued, so nothing new starts at once")
            try expectContains(transport.requests.last?.url.absoluteString ?? "", "gpu-box:8000/metrics")

            // Engines before v1 published the same gauge under another name.
            let older = MockTransport()
            older.stub("/metrics", json: "vllm:gpu_cache_usage_perc{model_name=\"m\"} 55.0")
            let legacy = try expectNotNil(try await OpenAIAdapter()
                .occupancy(server(.vllm, "http://gpu-box:8000/v1", older)))
            try expectEqual(legacy.kvCacheUsage, 0.55, "a percentage reads as the ratio it is")
        }

        test("SGLang publishes the same things under its own names") {
            let transport = MockTransport()
            transport.stub("/metrics", json: """
            sglang:num_running_reqs{model_name="m"} 1.0
            sglang:num_queue_reqs{model_name="m"} 0.0
            sglang:token_usage{model_name="m"} 0.55
            """)
            let busy = try expectNotNil(try await OpenAIAdapter()
                .occupancy(server(.sglang, "http://127.0.0.1:30000/v1", transport)))
            try expectEqual(busy.running, 1)
            try expectEqual(busy.queued, 0)
            try expectEqual(busy.utilization, 0.55)
            try expect(!busy.isSaturated)
        }

        test("llama.cpp counts the slots it is decoding in") {
            let transport = MockTransport()
            transport.stub("/slots", json: #"[{"id":0,"state":1},{"id":1,"state":0},{"id":2,"is_processing":true}]"#)
            let busy = try expectNotNil(try await OpenAIAdapter()
                .occupancy(server(.llamaCpp, "http://127.0.0.1:8080/v1", transport)))
            try expectEqual(busy.running, 2)
            try expectEqual(busy.totalSlots, 3)
            try expectClose(busy.utilization ?? 0, 2.0 / 3.0)
            try expect(!busy.isSaturated)
            try expect(ServerOccupancy(running: 3, totalSlots: 3).isSaturated, "every slot taken")
            try expectEqual(ServerOccupancy(running: 3, totalSlots: 3).summary, "3 of 3 slots busy")
        }

        test("a server that does not publish this is never asked") {
            let transport = MockTransport()
            try expectNil(try await OpenAIAdapter().occupancy(server(.ollama, "http://127.0.0.1:11434/v1", transport)))
            try expectNil(try await OpenAIAdapter()
                .occupancy(server(.openAICompatible, "http://enzotide:8000/v1", transport)))
            try expectEqual(transport.requests.count, 0)
        }

        test("the server's own account of its load outweighs Derby's view of it") {
            let box = account("Box", kind: .vllm, model: "qwen3.8-27b-fp8", capacity: 8)
            var snapshot = Fixture.snapshot(config([box], strategy: .leastLoaded))
            let target = try expectNotNil(snapshot.logicalModel(named: "x")?.targets.first)

            snapshot.accountLoad = [box.id: .init(inFlight: 1)]
            try expectClose(snapshot.loadUtilization(for: target), 0.125, tolerance: 0.001)
            snapshot.residency = [box.id: AccountResidency(occupancy: ServerOccupancy(kvCacheUsage: 0.8))]
            try expectClose(snapshot.loadUtilization(for: target), 0.8,
                            tolerance: 0.001)
            // Whichever is worse wins: Derby also knows what it has just sent.
            snapshot.accountLoad = [box.id: .init(inFlight: 8)]
            try expectClose(snapshot.loadUtilization(for: target), 1.0)

            snapshot.residency = [box.id: AccountResidency(occupancy: ServerOccupancy(kvCacheUsage: 0.8),
                                                           observedAt: Date().addingTimeInterval(-120))]
            snapshot.accountLoad = [:]
            try expectNil(snapshot.occupancy(for: target), "an old reading is not acted on")
            try expectEqual(snapshot.warmth(for: target), .unknown,
                            "a server that reports its load but not its models says nothing about warmth")
        }

        test("a full server is passed over, unless it is the only one that can answer") {
            let busy = account("Busy", kind: .vllm, model: "qwen3.8-27b-fp8")
            let free = account("Free", kind: .ollama, model: "qwen3.6:27b")
            let reports = [busy.id: AccountResidency(occupancy: ServerOccupancy(running: 4, queued: 3, totalSlots: 4))]

            let both = try route(config([busy, free], strategy: .priority), residency: reports)
            try expectEqual(order(both), ["Free"], "configured first, but it has no free slot")
            try expect(both.exclusions.contains { $0.reason.contains("queued") })

            let alone = try route(config([busy], strategy: .priority), residency: reports)
            try expectEqual(order(alone), ["Busy"], "queueing there beats failing the request")
        }

        test("the poller keeps what a server did answer when the other probe fails") {
            let transport = MockTransport()
            transport.stub("/metrics", json: "vllm:num_requests_running{model_name=\"m\"} 2.0")
            var box = Fixture.account("Box", kind: .vllm, models: [])
            box.baseURLOverride = "http://gpu-box:8000/v1"
            let registry = ResidencyRegistry()
            await DerbyEngine.pollResidency(config: Fixture.config(accounts: [box], logicalModels: []),
                                            adapters: AdapterRegistry(), transport: transport,
                                            secrets: InMemorySecretStore(), credentials: CredentialCache(),
                                            into: registry)
            let report = try expectNotNil(await registry.snapshot()[box.id])
            try expectEqual(report.occupancy?.running, 2)
            try expectNil(report.loadedModels, "the model list was not answered, and is not invented")
        }
    }

    // MARK: - Saved settings

    suite("Load / saved settings") {
        func object(_ value: some Encodable) throws -> [String: Any] {
            try expectNotNil(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }

        test("a logical model saved before these settings existed still loads, with them off") {
            let target = Fixture.account("A", models: [Fixture.model("m")])
            var json = try object(Fixture.logical("x", accounts: [target], strategy: .weightedScore))
            json.removeValue(forKey: "handoff")
            var policy = try expectNotNil(json["policy"] as? [String: Any])
            policy.removeValue(forKey: "preferWarmModels")
            var weights = try expectNotNil(policy["scoreWeights"] as? [String: Any])
            for key in ["load", "warmth", "continuity"] { weights.removeValue(forKey: key) }
            policy["scoreWeights"] = weights
            json["policy"] = policy

            let decoded = try JSONDecoder().decode(LogicalModel.self, from: JSONSerialization.data(withJSONObject: json))
            try expectNil(decoded.handoff)
            try expectEqual(decoded.policy.strategy, .weightedScore)
            try expect(decoded.policy.effectivePreferWarmModels, "on by default where order is not the instruction")
            let w = decoded.policy.scoreWeights
            try expectEqual(w.load + w.warmth + w.continuity, 0)
        }

        test("hand-off and warm-copy choices survive a save") {
            let target = Fixture.account("A", models: [Fixture.model("m")])
            var lm = Fixture.logical("x", accounts: [target], strategy: .leastLoaded)
            lm.handoff = HandoffPolicy(replayReasoning: false)
            lm.policy.preferWarmModels = false
            lm.policy.scoreWeights.continuity = 0.4
            let decoded = try JSONDecoder().decode(LogicalModel.self, from: JSONEncoder().encode(lm))
            try expectEqual(decoded.handoff?.replayReasoning, false)
            try expectEqual(decoded.policy.preferWarmModels, false)
            try expectEqual(decoded.policy.strategy, .leastLoaded)
            try expectEqual(decoded.policy.scoreWeights.continuity, 0.4)
        }

        test("a message stored without hand-off fields decodes") {
            var json = try object(CanonicalMessage.assistant("hi"))
            json.removeValue(forKey: "reasoningArtifacts")
            json.removeValue(forKey: "origin")
            let decoded = try JSONDecoder().decode(CanonicalMessage.self, from: JSONSerialization.data(withJSONObject: json))
            try expect(decoded.reasoningArtifacts.isEmpty)
            try expectNil(decoded.origin)
            try expectEqual(decoded.joinedText, "hi")
            try expect(try JSONDecoder().decode(HandoffPolicy.self, from: Data("{}".utf8)).replayReasoning)
        }
    }

    // MARK: - Through the gateway

    suite("Load / through the gateway") {
        func withGateway(strategy: RoutingStrategyKind, adapter: MockAdapter,
                         body: (Int) async throws -> Void) async throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-load-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let alpha = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            let beta = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let config = Fixture.config(accounts: [alpha, beta], logicalModels: [
                Fixture.logical("coding", accounts: [alpha, beta], strategy: strategy)])
            let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
            try store.save(config)
            let engine = DerbyEngine(configStore: store, secrets: InMemorySecretStore(), transport: MockTransport(),
                                     adapters: AdapterRegistry(adapters: [.openai: adapter]),
                                     telemetry: TelemetryStore(path: dir.appendingPathComponent("t.sqlite3").path,
                                                               settings: config.logging))
            await engine.bootstrap()
            try await engine.startGateway()
            guard case .running(let port, _) = await engine.status else {
                throw TestFailure(message: "gateway did not start: \(await engine.status)", file: #fileID, line: #line)
            }
            do { try await body(port) } catch { await engine.stopGateway(); throw error }
            await engine.stopGateway()
        }

        test("simultaneous requests spread out instead of all reading the same idle counts") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "a", delay: 0.6))
            adapter.set("m-b", .succeed(text: "b", delay: 0.6))
            try await withGateway(strategy: .leastLoaded, adapter: adapter) { port in
                let statuses = await withTaskGroup(of: Int.self) { group -> [Int] in
                    for i in 0..<4 {
                        group.addTask {
                            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                            req.httpMethod = "POST"
                            req.setValue("application/json", forHTTPHeaderField: "content-type")
                            req.httpBody = Data(#"{"model":"coding","messages":[{"role":"user","content":"request \#(i)"}]}"#.utf8)
                            guard let (_, response) = try? await URLSession.shared.data(for: req) else { return 0 }
                            return (response as? HTTPURLResponse)?.statusCode ?? 0
                        }
                    }
                    var out: [Int] = []
                    for await status in group { out.append(status) }
                    return out
                }
                try expectEqual(statuses, [200, 200, 200, 200])
                try expectEqual(adapter.calls("m-a"), 2, "without a reservation every request picks the same idle target")
                try expectEqual(adapter.calls("m-b"), 2)
            }
        }
    }
}
