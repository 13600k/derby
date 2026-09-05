import Foundation
@testable import DerbyCore

func registerRoutingTests() {
    suite("Routing / resolution") {
        test("resolves a logical model to its ordered targets") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            let b = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let config = Fixture.config(accounts: [a, b], logicalModels: [Fixture.logical("coding", accounts: [a, b])])
            let decision = try Fixture.decision(config, model: "coding")
            try expectEqual(decision.plan.attempts.count, 2)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Alpha")
            try expectEqual(decision.logicalModelName, "coding")
        }

        test("logical model lookup is case-insensitive") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m")])
            let config = Fixture.config(accounts: [a], logicalModels: [Fixture.logical("Coding", accounts: [a])])
            let decision = try Fixture.decision(config, model: "CODING")
            try expectEqual(decision.logicalModelName, "Coding")
        }

        test("unknown model returns MODEL_UNAVAILABLE and lists what exists") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m")])
            let config = Fixture.config(accounts: [a], logicalModels: [Fixture.logical("coding", accounts: [a])])
            let error = try await expectFailure(.modelUnavailable) {
                _ = try Fixture.decision(config, model: "nope")
            }
            try expectContains(error.message, "coding")
        }

        test("a logical model with no targets explains itself") {
            let config = Fixture.config(accounts: [], logicalModels: [LogicalModel(name: "empty")])
            let error = try await expectFailure(.modelUnavailable) {
                _ = try Fixture.decision(config, model: "empty")
            }
            try expectContains(error.message, "no targets")
        }

        test("disabled providers, models and targets are excluded with a reason") {
            var a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            var b = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let c = Fixture.account("Gamma", models: [Fixture.model("m-c")])
            a.enabled = false
            b.models[0].enabled = false
            var lm = Fixture.logical("coding", accounts: [a, b, c])
            let config = Fixture.config(accounts: [a, b, c], logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Gamma")
            try expectEqual(decision.exclusions.count, 2)
            try expect(decision.exclusions.allSatisfy { $0.stage == .disabled })

            // And a target switched off inside the logical model itself.
            lm.targets[2].enabled = false
            let config2 = Fixture.config(accounts: [a, b, c], logicalModels: [lm])
            _ = try await expectFailure(.modelUnavailable) { _ = try Fixture.decision(config2, model: "coding") }
        }
    }

    suite("Routing / capability filtering") {
        test("targets missing a required capability are filtered out") {
            let withTools = Fixture.account("Tools", models: [Fixture.model("t", caps: [.text, .streaming, .tools])])
            let noTools = Fixture.account("NoTools", models: [Fixture.model("n", caps: [.text, .streaming])])
            let config = Fixture.config(accounts: [withTools, noTools],
                                        logicalModels: [Fixture.logical("coding", accounts: [noTools, withTools])])
            let request = RoutingRequest(logicalModelName: "coding",
                                         requirements: CapabilityRequirements(required: [.text, .tools]),
                                         promptTokens: 100)
            let decision = try Router().route(request, snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Tools")
            let excluded = try expectNotNil(decision.exclusions.first)
            try expectEqual(excluded.stage, .capability)
            try expectContains(excluded.reason, "tools unsupported")
        }

        test("vision requests skip text-only targets") {
            let textOnly = Fixture.account("Text", models: [Fixture.model("t", caps: [.text, .streaming])])
            let vision = Fixture.account("Vision", models: [Fixture.model("v", caps: [.text, .streaming, .vision])])
            let config = Fixture.config(accounts: [textOnly, vision],
                                        logicalModels: [Fixture.logical("smart", accounts: [textOnly, vision])])
            var request = CanonicalRequest(requestedModel: "smart")
            request.messages = [CanonicalMessage(role: .user, content: [
                .text("what is this"), .image(CanonicalImage(base64: "AAA", mimeType: "image/png")),
            ])]
            let decision = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Vision")
        }

        test("a logical model narrows what it offers rather than demanding it") {
            // There is no user-set "required capabilities": demanding something no
            // target has could only empty the group. Narrowing is the supported
            // direction, and it is enforced.
            let capable = Fixture.account("Capable", models: [
                Fixture.model("c", caps: [.text, .streaming, .tools, .vision])])
            var lm = Fixture.logical("coding", accounts: [capable])
            lm.constraints = LogicalModelConstraints(allowedCapabilities: [.text, .streaming, .tools])
            let config = Fixture.config(accounts: [capable], logicalModels: [lm])

            // Text and tools still route.
            try expectEqual(try Fixture.decision(config, model: "coding").plan.attempts.count, 1)

            // Vision was withheld, so it is refused rather than routed anyway.
            var request = CanonicalRequest(requestedModel: "coding")
            request.messages = [CanonicalMessage(role: .user, content: [
                .image(CanonicalImage(base64: "AAA", mimeType: "image/png"))])]
            _ = try await expectFailure(.capabilityMismatch) {
                _ = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            }
        }

        test("a context window that is too small is filtered, larger one kept") {
            let small = Fixture.account("Small", models: [Fixture.model("s", context: 8_192)])
            let large = Fixture.account("Large", models: [Fixture.model("l", context: 200_000)])
            let config = Fixture.config(accounts: [small, large],
                                        logicalModels: [Fixture.logical("long", accounts: [small, large])])
            let request = RoutingRequest(logicalModelName: "long",
                                         requirements: CapabilityRequirements(required: [.text], minContextTokens: 100_000),
                                         promptTokens: 100_000)
            let decision = try Router().route(request, snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Large")
        }
    }

    suite("Routing / health and quota filtering") {
        test("targets with an open circuit are skipped and explained") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            let b = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let config = Fixture.config(accounts: [a, b], logicalModels: [Fixture.logical("coding", accounts: [a, b])])
            let key = TargetKey(providerID: a.id, modelID: "m-a")
            var health = TargetHealth(key: key)
            health.circuit = .open
            health.state = .unhealthy
            health.lastFailureKind = .providerDown
            health.circuitReopensAt = Date().addingTimeInterval(25)

            let decision = try Fixture.decision(config, model: "coding", health: [key: health])
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Beta")
            let excluded = try expectNotNil(decision.exclusions.first { $0.providerName == "Alpha" })
            try expectContains(excluded.reason, "circuit open")
            try expectEqual(excluded.stage, .health)
        }

        test("exhausted provider quota removes a target") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            let b = Fixture.account("Beta", models: [Fixture.model("m-b")])
            let config = Fixture.config(accounts: [a, b], logicalModels: [Fixture.logical("coding", accounts: [a, b])])
            let key = TargetKey(providerID: a.id, modelID: "m-a")
            var health = TargetHealth(key: key)
            health.rateLimit = RateLimitSnapshot(requestsLimit: 100, requestsRemaining: 0,
                                                 requestsResetSeconds: 60, observedAt: Date())
            let decision = try Fixture.decision(config, model: "coding", health: [key: health])
            try expectEqual(decision.plan.attempts[0].target.providerName, "Beta")
            try expect(decision.exclusions.contains { $0.stage == .quota })
        }

        test("circuit filtering can be turned off per logical model") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            var lm = Fixture.logical("coding", accounts: [a])
            lm.policy.respectCircuitBreakers = false
            let config = Fixture.config(accounts: [a], logicalModels: [lm])
            let key = TargetKey(providerID: a.id, modelID: "m-a")
            var health = TargetHealth(key: key)
            health.circuit = .open
            let decision = try Fixture.decision(config, model: "coding", health: [key: health])
            try expectEqual(decision.plan.attempts.count, 1)
        }
    }

    suite("Routing / budget") {
        test("a per-request cost cap filters expensive targets") {
            let pricey = Fixture.account("Pricey", models: [
                Fixture.model("expensive", pricing: Pricing(inputPerMTok: 100, outputPerMTok: 400))])
            let cheap = Fixture.account("Cheap", models: [
                Fixture.model("cheap", pricing: Pricing(inputPerMTok: 0.1, outputPerMTok: 0.4))])
            var lm = Fixture.logical("thrifty", accounts: [pricey, cheap])
            lm.budget = BudgetRules(maxCostPerRequestUSD: 0.01, degradeToFreeTargets: false)
            let config = Fixture.config(accounts: [pricey, cheap], logicalModels: [lm])
            let request = RoutingRequest(logicalModelName: "thrifty",
                                         requirements: CapabilityRequirements(required: [.text]),
                                         promptTokens: 50_000, maxOutputTokens: 4_000)
            let decision = try Router().route(request, snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Cheap")
            try expect(decision.exclusions.contains { $0.stage == .budget })
        }

        test("unknown pricing is never filtered by a budget cap") {
            let unknown = Fixture.account("Unknown", models: [Fixture.model("u", pricing: nil)])
            var lm = Fixture.logical("thrifty", accounts: [unknown])
            lm.budget = BudgetRules(maxCostPerRequestUSD: 0.000001)
            let config = Fixture.config(accounts: [unknown], logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "thrifty")
            try expectEqual(decision.plan.attempts.count, 1, "imperfect pricing metadata must not break routing")
        }
    }

    suite("Routing / plan shape") {
        test("candidate cap trims the plan and records why") {
            let accounts = (1...5).map { Fixture.account("P\($0)", models: [Fixture.model("m\($0)")]) }
            var lm = Fixture.logical("coding", accounts: accounts)
            lm.policy.maxCandidates = 2
            lm.failover = FailoverConfig(enabled: true, maxAttempts: 5)
            let config = Fixture.config(accounts: accounts, logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            try expectEqual(decision.plan.attempts.count, 2)
            try expectEqual(decision.exclusions.filter { $0.stage == .cap }.count, 3)
        }

        test("disabling failover leaves exactly one attempt") {
            let accounts = (1...3).map { Fixture.account("P\($0)", models: [Fixture.model("m\($0)")]) }
            var lm = Fixture.logical("coding", accounts: accounts)
            lm.failover = FailoverConfig(enabled: false, maxAttempts: 4)
            let config = Fixture.config(accounts: accounts, logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            try expectEqual(decision.plan.attempts.count, 1)
        }

        test("per-target timeout override is carried into the plan") {
            let a = Fixture.account("Alpha", models: [Fixture.model("m-a")])
            var lm = Fixture.logical("coding", accounts: [a])
            lm.targets[0].timeoutOverrideSeconds = 2.5
            let config = Fixture.config(accounts: [a], logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "coding")
            try expectEqual(decision.plan.attempts[0].timeout, 2.5)
        }

        test("the failover chain strategy disables hedging") {
            let accounts = (1...2).map { Fixture.account("P\($0)", models: [Fixture.model("m\($0)")]) }
            let lm = Fixture.logical("chain", accounts: accounts, strategy: .failoverChain,
                                     hedging: HedgeConfig(enabled: true, delaySeconds: 0.1))
            let config = Fixture.config(accounts: accounts, logicalModels: [lm])
            let decision = try Fixture.decision(config, model: "chain")
            try expect(!decision.plan.hedging.enabled, "a strict chain must never run targets in parallel")
        }

        test("the decision trace explains inclusions and exclusions") {
            let ok = Fixture.account("Good", models: [Fixture.model("g", caps: [.text, .streaming, .tools])])
            let bad = Fixture.account("Bad", models: [Fixture.model("b", caps: [.text, .streaming])])
            let config = Fixture.config(accounts: [ok, bad],
                                        logicalModels: [Fixture.logical("coding", accounts: [ok, bad])])
            let request = RoutingRequest(logicalModelName: "coding",
                                         requirements: CapabilityRequirements(required: [.text, .tools]),
                                         promptTokens: 100)
            let decision = try Router().route(request, snapshot: Fixture.snapshot(config))
            let trace = decision.trace
            try expectContains(trace, "Requested logical model: coding")
            try expectContains(trace, "✓ Good")
            try expectContains(trace, "✗ Bad")
            try expectContains(trace, "tools unsupported")
            try expectContains(trace, "Selected: Good")
        }

        test("context-overflow reordering prefers a larger window") {
            let small = Fixture.account("Small", models: [Fixture.model("s", context: 8_000)])
            let mid = Fixture.account("Mid", models: [Fixture.model("m", context: 32_000)])
            let large = Fixture.account("Large", models: [Fixture.model("l", context: 500_000)])
            let config = Fixture.config(accounts: [small, mid, large],
                                        logicalModels: [Fixture.logical("x", accounts: [small, mid, large])])
            let decision = try Fixture.decision(config, model: "x")
            let failed = decision.plan.attempts[0].target
            let reordered = Router.preferringLargerContext(than: failed, attempts: Array(decision.plan.attempts.dropFirst()))
            try expectEqual(reordered.first?.target.providerName, "Mid")
            try expect((reordered[0].target.capabilities.contextWindow ?? 0) > (failed.capabilities.contextWindow ?? 0))
        }
    }
}
