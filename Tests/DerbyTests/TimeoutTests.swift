import Foundation
@testable import DerbyCore

/// Timeouts come from two scopes that mean different things — a logical model's
/// patience and an endpoint's requirement — and used to be joined with `min`, so
/// a provider could only ever make Derby stricter. These pin the rule that
/// replaced it, including the part that must hold for a provider kind nobody has
/// written yet.
func registerTimeoutTests() {

    suite("Timeouts / resolution") {

        let policy = TimeoutConfig(overallSeconds: 600, perAttemptSeconds: 120, firstTokenSeconds: 60)

        test("a provider that needs longer than the policy allows gets it") {
            let resolved = ResolvedTimeouts.resolve(
                logicalModel: policy,
                account: AccountTimeouts(requestSeconds: 600, firstTokenSeconds: 300))
            try expectEqual(resolved.attemptSeconds, 600)
            try expectEqual(resolved.firstTokenSeconds, 300)
        }

        test("a provider that states nothing leaves the logical model in charge") {
            let resolved = ResolvedTimeouts.resolve(logicalModel: policy, account: .unstated)
            try expectEqual(resolved.attemptSeconds, 120)
            try expectEqual(resolved.firstTokenSeconds, 60)
        }

        test("a logical model can still be the stricter of the pair") {
            let strict = TimeoutConfig(overallSeconds: 45, perAttemptSeconds: 20, firstTokenSeconds: 10)
            let resolved = ResolvedTimeouts.resolve(logicalModel: strict, account: .unstated)
            try expectEqual(resolved.attemptSeconds, 20)
            try expectEqual(resolved.firstTokenSeconds, 10)
        }

        test("a policy more patient than the endpoint is not cut down by it") {
            let resolved = ResolvedTimeouts.resolve(
                logicalModel: policy,
                account: AccountTimeouts(requestSeconds: 30, firstTokenSeconds: 15))
            try expectEqual(resolved.attemptSeconds, 120)
            try expectEqual(resolved.firstTokenSeconds, 60)
        }

        test("waiting for a first token never outlasts the attempt waiting for it") {
            let resolved = ResolvedTimeouts.resolve(
                logicalModel: TimeoutConfig(overallSeconds: 60, perAttemptSeconds: 30, firstTokenSeconds: 45),
                account: .unstated)
            try expectEqual(resolved.attemptSeconds, 30)
            try expectEqual(resolved.firstTokenSeconds, 30)
        }

        test("a per-target override replaces the pair rather than joining it") {
            let resolved = ResolvedTimeouts.resolve(
                logicalModel: policy,
                account: AccountTimeouts(requestSeconds: 600, firstTokenSeconds: 300),
                targetOverrideSeconds: 45)
            try expectEqual(resolved.attemptSeconds, 45)
            try expectEqual(resolved.firstTokenSeconds, 45)
        }
    }

    suite("Timeouts / provider kinds") {

        // The repeatable part: a kind declares its timing once, and everything
        // downstream reads it. A kind added later is covered by these without a
        // line being added here.
        test("every kind that can be slow to speak declares how long it needs") {
            for kind in ProviderKind.allCases where kind.isLocal || kind.cliCredentialSource != nil {
                let stated = kind.defaultTimeouts
                try expect(stated.firstTokenSeconds ?? 0 >= 180,
                           "\(kind.rawValue) prefills or spawns before it answers, so it must ask for more than an HTTP round trip")
                try expect(stated.requestSeconds ?? 0 >= 600, "\(kind.rawValue) needs a long attempt ceiling")
            }
        }

        test("a metered API asks for nothing, so its logical model decides alone") {
            for kind in ProviderKind.allCases
            where !kind.isLocal && kind.cliCredentialSource == nil
                && kind != .openAICompatible && kind != .bedrock {
                try expectEqual(kind.defaultTimeouts.requestSeconds, nil)
                try expectEqual(kind.defaultTimeouts.firstTokenSeconds, nil)
            }
        }

        test("an account states only what it was given, never a kind default") {
            let bare = ProviderAccount(name: "vLLM", kind: .vllm)
            try expectEqual(bare.statedTimeouts.requestSeconds, nil)
            try expectEqual(bare.statedTimeouts.firstTokenSeconds, nil)
            // Work with no logical model behind it still needs a number.
            try expectEqual(bare.outOfBandTimeoutSeconds, 600)
        }
    }

    suite("Timeouts / planning") {

        test("raising a provider's timeout raises the attempt the router plans") {
            var slow = Fixture.account("Slow box", kind: .vllm, models: [Fixture.model("q")])
            slow.requestTimeoutSeconds = 600
            slow.firstTokenTimeoutSeconds = 300
            let lm = Fixture.logical("smart", accounts: [slow],
                                     timeouts: TimeoutConfig(overallSeconds: 600, perAttemptSeconds: 120,
                                                             firstTokenSeconds: 60))
            let decision = try Fixture.decision(Fixture.config(accounts: [slow], logicalModels: [lm]),
                                                model: "smart")
            let planned = try expectNotNil(decision.plan.attempts.first)
            try expectEqual(planned.timeout, 600)
            try expectEqual(planned.firstTokenTimeout, 300)
        }

        test("the same policy against a provider that states nothing is unchanged") {
            let plain = Fixture.account("Metered", kind: .openai, models: [Fixture.model("g")])
            let lm = Fixture.logical("smart", accounts: [plain],
                                     timeouts: TimeoutConfig(overallSeconds: 600, perAttemptSeconds: 120,
                                                             firstTokenSeconds: 60))
            let decision = try Fixture.decision(Fixture.config(accounts: [plain], logicalModels: [lm]),
                                                model: "smart")
            let planned = try expectNotNil(decision.plan.attempts.first)
            try expectEqual(planned.timeout, 120)
            try expectEqual(planned.firstTokenTimeout, 60)
        }

        test("each attempt carries its own endpoint's patience, not the plan's") {
            var slow = Fixture.account("Slow box", kind: .llamaCpp, models: [Fixture.model("a")])
            slow.firstTokenTimeoutSeconds = 300
            let quick = Fixture.account("Metered", kind: .openai, models: [Fixture.model("b")])
            let lm = Fixture.logical("smart", accounts: [slow, quick],
                                     timeouts: TimeoutConfig(overallSeconds: 600, perAttemptSeconds: 200,
                                                             firstTokenSeconds: 60))
            let decision = try Fixture.decision(Fixture.config(accounts: [slow, quick], logicalModels: [lm]),
                                                model: "smart")
            let byName = Dictionary(uniqueKeysWithValues: decision.plan.attempts.map { ($0.target.providerName, $0) })
            try expectEqual(byName["Slow box"]?.firstTokenTimeout, 200)
            try expectEqual(byName["Metered"]?.firstTokenTimeout, 60)
        }

        test("the resolved budget is written into the decision trace") {
            var slow = Fixture.account("Slow box", kind: .vllm, models: [Fixture.model("q")])
            slow.requestTimeoutSeconds = 600
            let lm = Fixture.logical("smart", accounts: [slow],
                                     timeouts: TimeoutConfig(overallSeconds: 600, perAttemptSeconds: 120,
                                                             firstTokenSeconds: 60))
            let decision = try Fixture.decision(Fixture.config(accounts: [slow], logicalModels: [lm]),
                                                model: "smart")
            try expectContains(decision.trace, "Budget:")
            try expectContains(decision.trace, "attempt 600.00 s")
        }
    }

    func makeExecutor(_ adapter: MockAdapter) -> Executor {
        Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                 transport: MockTransport(), secrets: InMemorySecretStore(),
                 credentials: CredentialCache(),
                 health: HealthRegistry(settings: HealthSettings(windowSize: 20, failureThreshold: 2,
                                                                 minimumSamples: 2, openDurationSeconds: 60)),
                 telemetry: RecordingSink())
    }

    suite("Timeouts / execution") {

        // The symptom that started this: a local server that prefills a long
        // conversation was called stalled at the logical model's first-token
        // timeout, and raising the provider's own could not save it.
        test("a provider's first-token timeout keeps a slow stream alive past the policy's") {
            let adapter = MockAdapter()
            adapter.set("m-a", .succeed(text: "alpha", delay: 0.6))
            adapter.set("m-b", .succeed(text: "beta"))
            var slow = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            slow.firstTokenTimeoutSeconds = 5
            let quick = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let lm = Fixture.logical("coding", accounts: [slow, quick],
                                     timeouts: TimeoutConfig(overallSeconds: 10, perAttemptSeconds: 8,
                                                             firstTokenSeconds: 0.2))
            let config = Fixture.config(accounts: [slow, quick], logicalModels: [lm])
            let ex = makeExecutor(adapter)
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true

            var record: RequestRecord?
            for try await event in ex.stream(request, decision: try Fixture.decision(config, model: "coding"),
                                             meta: RequestMeta()) {
                if case .finished(let r) = event { record = r }
            }
            // Without the provider's 5 s this would have been abandoned at 0.2 s
            // and answered by Beta.
            try expectEqual(try expectNotNil(record).finalProviderName, "Alpha")
        }

        test("a provider that states nothing is still abandoned at the policy's first-token timeout") {
            let adapter = MockAdapter()
            adapter.set("m-a", .hang(seconds: 30))
            adapter.set("m-b", .succeed(text: "beta"))
            let slow = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            let quick = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let lm = Fixture.logical("coding", accounts: [slow, quick],
                                     timeouts: TimeoutConfig(overallSeconds: 6, perAttemptSeconds: 5,
                                                             firstTokenSeconds: 0.3))
            let config = Fixture.config(accounts: [slow, quick], logicalModels: [lm])
            let ex = makeExecutor(adapter)
            var request = CanonicalRequest(requestedModel: "coding")
            request.stream = true

            var record: RequestRecord?
            let started = Date()
            for try await event in ex.stream(request, decision: try Fixture.decision(config, model: "coding"),
                                             meta: RequestMeta()) {
                if case .finished(let r) = event { record = r }
            }
            try expect(Date().timeIntervalSince(started) < 3)
            try expectEqual(try expectNotNil(record).finalProviderName, "Beta")
        }
    }

    suite("Timeouts / migration") {

        test("an existing provider is given the first-token timeout its kind needs") {
            var raw: [String: Any] = [
                "schemaVersion": 2,
                "providers": [
                    ["name": "enzotide", "kind": "vllm", "requestTimeoutSeconds": 600],
                    ["name": "OpenAI", "kind": "openai", "requestTimeoutSeconds": 120],
                ],
            ]
            let notes = ConfigMigrator.migrate(rawObject: &raw)
            let providers = try expectNotNil(raw["providers"] as? [[String: Any]])
            try expectEqual(providers[0]["firstTokenTimeoutSeconds"] as? Double, 300)
            // A metered API asks for nothing, so nothing is invented for it.
            try expectNil(providers[1]["firstTokenTimeoutSeconds"])
            try expectEqual(raw["schemaVersion"] as? Int, 3)
            try expect(notes.contains { $0.contains("enzotide") }, "the change must not be silent")
        }

        test("a first-token timeout the user already set is left alone") {
            var raw: [String: Any] = [
                "schemaVersion": 2,
                "providers": [["name": "enzotide", "kind": "vllm", "firstTokenTimeoutSeconds": 45.0]],
            ]
            _ = ConfigMigrator.migrate(rawObject: &raw)
            let providers = try expectNotNil(raw["providers"] as? [[String: Any]])
            try expectEqual(providers[0]["firstTokenTimeoutSeconds"] as? Double, 45)
        }
    }

    suite("Timeouts / the overall deadline is the ceiling") {

        test("a provider cannot plan to outlast the request it belongs to") {
            let resolved = ResolvedTimeouts.resolve(
                logicalModel: TimeoutConfig(overallSeconds: 180, perAttemptSeconds: 120, firstTokenSeconds: 60),
                account: AccountTimeouts(requestSeconds: 600, firstTokenSeconds: 300))
            try expectEqual(resolved.attemptSeconds, 180)
            try expectEqual(resolved.firstTokenSeconds, 180)
        }

        test("nor can a per-target override") {
            let resolved = ResolvedTimeouts.resolve(
                logicalModel: TimeoutConfig(overallSeconds: 30, perAttemptSeconds: 20, firstTokenSeconds: 10),
                account: .unstated,
                targetOverrideSeconds: 600)
            try expectEqual(resolved.attemptSeconds, 30)
        }
    }
}
