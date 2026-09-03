import Foundation
@testable import DerbyCore

func registerExecutionTests() {
    func makeExecutor(_ adapter: MockAdapter, sink: RecordingSink = RecordingSink(),
                      settings: HealthSettings = HealthSettings(windowSize: 20, failureThreshold: 2,
                                                                minimumSamples: 2, openDurationSeconds: 60))
        -> (Executor, HealthRegistry, RecordingSink) {
        let health = HealthRegistry(settings: settings)
        let ex = Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                          transport: MockTransport(), secrets: InMemorySecretStore(),
                          credentials: CredentialCache(), health: health, telemetry: sink)
        return (ex, health, sink)
    }

    func twoProviders(retry: RetryConfig = RetryConfig(maxRetriesPerTarget: 0, initialBackoffSeconds: 0.001),
                      failover: FailoverConfig = .default,
                      timeouts: TimeoutConfig = TimeoutConfig(overallSeconds: 10, perAttemptSeconds: 5, firstTokenSeconds: 3),
                      hedging: HedgeConfig = .disabled) -> DerbyConfig {
        let a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
        let b = Fixture.account("Beta", models: [Fixture.model("m-b")])
        return Fixture.config(accounts: [a, b],
                              logicalModels: [Fixture.logical("coding", accounts: [a, b], retry: retry,
                                                              failover: failover, timeouts: timeouts,
                                                              hedging: hedging)])
    }

    suite("Execution / success path") {
        test("a successful request records usage, cost and the chosen target") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "hello there",
                                        usage: CanonicalUsage(inputTokens: 100, outputTokens: 20)))
            let (ex, _, sink) = makeExecutor(adapter)
            var config = twoProviders()
            config.providers[0].models[0].pricingOverride = Pricing(inputPerMTok: 10, outputPerMTok: 30)
            let decision = try Fixture.decision(config, model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(outcome.response.message.joinedText, "hello there")
            try expectEqual(outcome.target.providerName, "Alpha")
            try expectEqual(outcome.record.attempts.count, 1)
            try expectEqual(outcome.record.usage.inputTokens, 100)
            try expectClose(outcome.record.costUSD, 100 * 10 / 1e6 + 20 * 30 / 1e6, tolerance: 1e-9)
            try expectEqual(sink.records.count, 1)
            try expect(sink.last?.succeeded == true)
        }

        test("logical model defaults fill in what the client omitted") {
            let adapter = MockAdapter()
            let (ex, _, _) = makeExecutor(adapter)
            var config = twoProviders()
            config.logicalModels[0].defaults = RequestDefaults(temperature: 0.15, maxOutputTokens: 321,
                                                               systemPrompt: "House style.",
                                                               systemPromptMode: .prepend)
            let decision = try Fixture.decision(config, model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.messages = [.user("hi")]
            let applied = ex.applyDefaults(request, plan: decision.plan)
            try expectEqual(applied.temperature, 0.15)
            try expectEqual(applied.maxOutputTokens, 321)
            try expectEqual(applied.messages.first?.role, .system)
            try expectEqual(applied.messages.first?.joinedText, "House style.")
        }

        test("a client-supplied value is never overwritten by a default") {
            let adapter = MockAdapter()
            let (ex, _, _) = makeExecutor(adapter)
            var config = twoProviders()
            config.logicalModels[0].defaults = RequestDefaults(temperature: 0.9)
            let decision = try Fixture.decision(config, model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.temperature = 0.1
            try expectEqual(ex.applyDefaults(request, plan: decision.plan).temperature, 0.1)
        }
    }

    suite("Execution / retry") {
        test("a transient failure is retried on the same target") {
            let adapter = MockAdapter()
            adapter.set("m-a", .failThenSucceed(count: 1,
                                                error: DerbyError(kind: .transient, message: "boom", providerStatus: 500),
                                                text: "recovered"))
            let (ex, _, _) = makeExecutor(adapter)
            let config = twoProviders(retry: RetryConfig(maxRetriesPerTarget: 2, initialBackoffSeconds: 0.001))
            let decision = try Fixture.decision(config, model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(outcome.response.message.joinedText, "recovered")
            try expectEqual(outcome.target.providerName, "Alpha", "retry must stay on the same provider")
            try expectEqual(adapter.calls("m-a"), 2)
            try expectEqual(adapter.calls("m-b"), 0, "no failover should have happened")
            try expectEqual(outcome.record.attempts[0].retryCount, 1)
            try expectEqual(outcome.record.failoverCount, 0)
        }

        test("the retry budget is respected, then failover happens") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .transient, message: "always", providerStatus: 500)))
            adapter.set("m-b", .succeed(text: "from beta"))
            let (ex, _, _) = makeExecutor(adapter)
            let config = twoProviders(retry: RetryConfig(maxRetriesPerTarget: 2, initialBackoffSeconds: 0.001))
            let decision = try Fixture.decision(config, model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(adapter.calls("m-a"), 3, "one attempt plus two retries")
            try expectEqual(outcome.target.providerName, "Beta")
            try expectEqual(outcome.record.failoverCount, 1)
        }

        test("rate limits fail over instead of retrying the same target") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, _, _) = makeExecutor(adapter)
            let config = twoProviders(retry: RetryConfig(maxRetriesPerTarget: 3, initialBackoffSeconds: 0.001))
            let decision = try Fixture.decision(config, model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(adapter.calls("m-a"), 1, "429 must not be retried on the same target")
            try expectEqual(outcome.target.providerName, "Beta")
        }
    }

    suite("Execution / failover and failure taxonomy") {
        test("an invalid request is returned to the client without failover") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .invalidRequest, message: "bad tool schema", providerStatus: 400)))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, _, _) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            let error = try await expectFailure(.invalidRequest) {
                _ = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                         decision: decision, meta: RequestMeta())
            }
            try expectContains(error.message, "bad tool schema")
            try expectEqual(adapter.calls("m-b"), 0, "a client error must not be retried elsewhere")
        }

        test("authentication failures fail over and are recorded") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .authentication, message: "401", providerStatus: 401)))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, health, _) = makeExecutor(adapter)
            let config = twoProviders()
            let decision = try Fixture.decision(config, model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(outcome.target.providerName, "Beta")
            let h = await health.health(for: TargetKey(providerID: config.providers[0].id, modelID: "m-a"))
            try expectEqual(h.lastFailureKind, .authentication)
        }

        test("when every target fails the last error surfaces with full history") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .providerDown, message: "alpha down", providerStatus: 503)))
            adapter.set("m-b", .fail(DerbyError(kind: .providerDown, message: "beta down", providerStatus: 503)))
            let (ex, _, sink) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            _ = try await expectFailure(.providerDown) {
                _ = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                         decision: decision, meta: RequestMeta())
            }
            let record = try expectNotNil(sink.last)
            try expectEqual(record.attempts.count, 2)
            try expect(!record.succeeded)
            try expectEqual(record.attempts.map(\.providerName), ["Alpha", "Beta"])
            try expectContains(record.routingExplanation, "attempt")
        }

        test("maxAttempts caps how many providers are tried") {
            let accounts = (1...4).map { Fixture.account("P\($0)", models: [Fixture.model("m\($0)")]) }
            let adapter = MockAdapter()
            adapter.defaultBehaviour = .fail(DerbyError(kind: .transient, message: "x", providerStatus: 500))
            let (ex, _, _) = makeExecutor(adapter)
            let lm = Fixture.logical("coding", accounts: accounts,
                                     failover: FailoverConfig(enabled: true, maxAttempts: 2))
            let config = Fixture.config(accounts: accounts, logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            _ = try await expectThrows {
                _ = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                         decision: decision, meta: RequestMeta())
            }
            try expectEqual(adapter.totalCalls, 2)
        }

        test("a custom disposition table changes behaviour without code changes") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, _, _) = makeExecutor(adapter)
            // Treat rate limits as fatal for this logical model.
            let failover = FailoverConfig(enabled: true, maxAttempts: 4,
                                          dispositions: [.rateLimit: .returnToClient])
            let decision = try Fixture.decision(twoProviders(failover: failover), model: "coding")
            _ = try await expectFailure(.rateLimit) {
                _ = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                         decision: decision, meta: RequestMeta())
            }
            try expectEqual(adapter.calls("m-b"), 0)
        }

        test("context overflow prefers a larger-context target next") {
            let small = Fixture.account("Small", models: [Fixture.model("s", context: 8_000)])
            let mid = Fixture.account("Mid", models: [Fixture.model("m", context: 32_000)])
            let large = Fixture.account("Large", models: [Fixture.model("l", context: 500_000)])
            let adapter = MockAdapter()
            adapter.set("s", .fail(DerbyError(kind: .contextOverflow, message: "too long", providerStatus: 400)))
            adapter.set("m", .succeed(text: "mid answered"))
            adapter.set("l", .succeed(text: "large answered"))
            let (ex, _, _) = makeExecutor(adapter)
            // Order the plan so the *smallest* remaining target is next; the
            // overflow disposition must reorder it.
            let lm = Fixture.logical("x", accounts: [small, mid, large])
            let config = Fixture.config(accounts: [small, mid, large], logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "x")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "x"),
                                               decision: decision, meta: RequestMeta())
            try expect(outcome.target.capabilities.contextWindow ?? 0 > 8_000)
        }
    }

    suite("Execution / timeouts") {
        test("a hung provider is abandoned at the per-attempt timeout and failed over") {
            let adapter = MockAdapter()
            adapter.set("m-a", .hang(seconds: 30))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, _, _) = makeExecutor(adapter)
            let config = twoProviders(timeouts: TimeoutConfig(overallSeconds: 5, perAttemptSeconds: 0.3,
                                                              firstTokenSeconds: 0.3))
            let decision = try Fixture.decision(config, model: "coding")
            let started = Date()
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            let elapsed = Date().timeIntervalSince(started)
            try expectEqual(outcome.target.providerName, "Beta")
            try expect(elapsed < 3, "should have given up on Alpha quickly, took \(elapsed)s")
            try expectEqual(outcome.record.attempts[0].failureKind, .timeout)
        }

        test("the overall deadline stops the chain even with targets left") {
            let accounts = (1...4).map { Fixture.account("P\($0)", models: [Fixture.model("m\($0)")]) }
            let adapter = MockAdapter()
            adapter.defaultBehaviour = .hang(seconds: 30)
            let (ex, _, _) = makeExecutor(adapter)
            let lm = Fixture.logical("coding", accounts: accounts,
                                     failover: FailoverConfig(enabled: true, maxAttempts: 4),
                                     timeouts: TimeoutConfig(overallSeconds: 0.9, perAttemptSeconds: 0.3,
                                                             firstTokenSeconds: 0.3))
            let config = Fixture.config(accounts: accounts, logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            let started = Date()
            _ = try await expectFailure(.timeout) {
                _ = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                         decision: decision, meta: RequestMeta())
            }
            let elapsed = Date().timeIntervalSince(started)
            try expect(elapsed < 2.5, "overall deadline was not enforced (took \(elapsed)s)")
            try expect(adapter.totalCalls < 4, "should not have reached every target inside the budget")
        }
    }

    suite("Execution / streaming") {
        test("streams deltas and reports a final record") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "one two three"))
            let (ex, _, _) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true

            var text = ""
            var record: RequestRecord?
            for try await event in ex.stream(request, decision: decision, meta: RequestMeta()) {
                switch event {
                case .canonical(.textDelta(let t)): text += t
                case .finished(let r): record = r
                default: break
                }
            }
            try expectEqual(text.trimmingCharacters(in: .whitespaces), "one two three")
            let r = try expectNotNil(record)
            try expect(r.succeeded)
            try expect(r.timeToFirstTokenSeconds != nil, "TTFT must be measured for streams")
        }

        test("a pre-stream failure fails over transparently") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .providerDown, message: "down", providerStatus: 503)))
            adapter.set("m-b", .succeed(text: "beta text"))
            let (ex, _, _) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true

            var text = ""
            var record: RequestRecord?
            for try await event in ex.stream(request, decision: decision, meta: RequestMeta()) {
                switch event {
                case .canonical(.textDelta(let t)): text += t
                case .finished(let r): record = r
                default: break
                }
            }
            try expectEqual(text.trimmingCharacters(in: .whitespaces), "beta text")
            let r = try expectNotNil(record)
            try expectEqual(r.finalProviderName, "Beta")
            try expectEqual(r.attempts.count, 2, "the failed first attempt is still recorded")
        }

        test("a mid-stream failure ends the stream instead of splicing providers") {
            let adapter = MidStreamFailAdapter(failAfterTokens: 3)
            let health = HealthRegistry()
            let sink = RecordingSink()
            let ex = Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                              transport: MockTransport(), secrets: InMemorySecretStore(),
                              credentials: CredentialCache(), health: health, telemetry: sink)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true

            var text = ""
            var failed: DerbyError?
            var finished = false
            for try await event in ex.stream(request, decision: decision, meta: RequestMeta()) {
                switch event {
                case .canonical(.textDelta(let t)): text += t
                case .failed(let e, _): failed = e
                case .finished: finished = true
                default: break
                }
            }
            try expect(text.contains("tok0"), "partial content should have been delivered")
            try expect(failed != nil, "a mid-stream failure must be surfaced, not hidden")
            try expect(!finished, "the stream must not report success after failing mid-flight")
            try expect(!text.contains("tok0 tok1 tok2 tok0"), "content must not be spliced from two attempts")
        }

        test("a silent provider trips the first-token timeout and fails over") {
            let adapter = MockAdapter()
            adapter.set("m-a", .hang(seconds: 30))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, _, _) = makeExecutor(adapter)
            let config = twoProviders(timeouts: TimeoutConfig(overallSeconds: 6, perAttemptSeconds: 5,
                                                              firstTokenSeconds: 0.3))
            let decision = try Fixture.decision(config, model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true

            var record: RequestRecord?
            let started = Date()
            for try await event in ex.stream(request, decision: decision, meta: RequestMeta()) {
                if case .finished(let r) = event { record = r }
            }
            try expect(Date().timeIntervalSince(started) < 3)
            try expectEqual(try expectNotNil(record).finalProviderName, "Beta")
        }
    }

    suite("Execution / usage reporting") {
        test("a stream with no provider usage is estimated and flagged") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "one two three four five six seven eight",
                                        usage: .zero))
            let (ex, _, _) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.messages = [.user("hello")]
            request.stream = true

            var record: RequestRecord?
            for try await event in ex.stream(request, decision: decision, meta: RequestMeta()) {
                if case .finished(let r) = event { record = r }
            }
            let usage = try expectNotNil(record).usage
            try expect(usage.isEstimated, "usage Derby derived itself must be marked estimated")
            try expect(usage.outputTokens > 0, "estimate should be non-zero")
            try expect(usage.inputTokens > 0)
        }

        test("provider-reported usage is used verbatim and never marked estimated") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "hi", usage: CanonicalUsage(inputTokens: 33, outputTokens: 7)))
            let (ex, _, _) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true
            var record: RequestRecord?
            for try await event in ex.stream(request, decision: decision, meta: RequestMeta()) {
                if case .finished(let r) = event { record = r }
            }
            let usage = try expectNotNil(record).usage
            try expectEqual(usage.inputTokens, 33)
            try expectEqual(usage.outputTokens, 7)
            try expect(!usage.isEstimated)
        }
    }

    suite("Execution / hedging") {
        test("a slow primary is overtaken by the hedge, and the loser is recorded") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "slow alpha", delay: 1.2))
            adapter.set("m-b", .succeed(text: "fast beta", delay: 0.0))
            let (ex, _, _) = makeExecutor(adapter)
            let config = twoProviders(hedging: HedgeConfig(enabled: true, delaySeconds: 0.15, maxParallel: 2))
            let decision = try Fixture.decision(config, model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(outcome.response.message.joinedText, "fast beta")
            try expect(outcome.record.attempts.contains { $0.status == .hedgeLost })
        }

        test("hedging stays off by default") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "alpha", delay: 0.3))
            adapter.set("m-b", .succeed(text: "beta"))
            let (ex, _, _) = makeExecutor(adapter)
            let decision = try Fixture.decision(twoProviders(), model: "coding")
            let outcome = try await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())
            try expectEqual(outcome.response.message.joinedText, "alpha")
            try expectEqual(adapter.calls("m-b"), 0, "no speculative spend without opting in")
        }
    }

    suite("Execution / concurrency") {
        test("many simultaneous requests all complete") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "ok", delay: 0.02))
            let (ex, _, _) = makeExecutor(adapter)
            // Capacity deliberately exceeds the load: this test is about
            // concurrency *safety*, not load shedding, which the next test covers.
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")], maxConcurrent: 64)
            let b = Fixture.account("Beta", models: [Fixture.model("m-b")], maxConcurrent: 64)
            let config = Fixture.config(accounts: [a, b],
                                        logicalModels: [Fixture.logical("coding", accounts: [a, b])])
            let decision = try Fixture.decision(config, model: "coding")
            let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                for _ in 0..<25 {
                    group.addTask {
                        (try? await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                               decision: decision, meta: RequestMeta())) != nil
                    }
                }
                var out: [Bool] = []
                for await r in group { out.append(r) }
                return out
            }
            try expectEqual(results.filter { $0 }.count, 25)
        }

        test("provider concurrency limits shed load onto the next target") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")], maxConcurrent: 1)
            let b = Fixture.account("Beta", models: [Fixture.model("m-b")], maxConcurrent: 8)
            let config = Fixture.config(accounts: [a, b],
                                        logicalModels: [Fixture.logical("coding", accounts: [a, b])])
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "alpha", delay: 0.4))
            adapter.set("m-b", .succeed(text: "beta"))
            let health = HealthRegistry()
            await health.update(accountLimits: [a.id: 1, b.id: 8])
            let ex = Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                              transport: MockTransport(), secrets: InMemorySecretStore(),
                              credentials: CredentialCache(), health: health, telemetry: RecordingSink())
            let decision = try Fixture.decision(config, model: "coding")

            let providers = await withTaskGroup(of: String?.self) { group -> [String] in
                for _ in 0..<6 {
                    group.addTask {
                        try? await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                              decision: decision, meta: RequestMeta()).target.providerName
                    }
                }
                var out: [String] = []
                for await p in group { if let p { out.append(p) } }
                return out
            }
            try expectEqual(providers.count, 6)
            try expect(providers.contains("Beta"), "requests over Alpha's concurrency limit should shift to Beta")
        }
    }

    suite("Execution / embeddings") {
        test("embeddings route and fail over like chat requests") {
            let adapter = MockAdapter()
            let (ex, _, _) = makeExecutor(adapter)
            let a = Fixture.account("Alpha", models: [Fixture.model("e-a", caps: [.embeddings])])
            let config = Fixture.config(accounts: [a], logicalModels: [Fixture.logical("embed", accounts: [a])])
            let request = CanonicalEmbeddingRequest(requestedModel: "embed", inputs: ["a", "b"])
            let decision = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            let outcome = try await ex.embed(request, decision: decision, meta: RequestMeta(dialect: .embeddings))
            try expectEqual(outcome.response.vectors.count, 2)
            try expect(outcome.record.succeeded)
        }
    }
}
