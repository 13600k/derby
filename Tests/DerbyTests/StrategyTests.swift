import Foundation
@testable import DerbyCore

func registerStrategyTests() {
    /// Three targets that differ on every scoring dimension.
    func spread() -> (DerbyConfig, ProviderAccount, ProviderAccount, ProviderAccount) {
        let premium = Fixture.account("Premium", models: [
            Fixture.model("big", quality: 95, pricing: Pricing(inputPerMTok: 15, outputPerMTok: 75))],
            preference: 80)
        let midrange = Fixture.account("Midrange", models: [
            Fixture.model("mid", quality: 80, pricing: Pricing(inputPerMTok: 1, outputPerMTok: 4))],
            preference: 50)
        let local = Fixture.account("Local", kind: .ollama, models: [
            Fixture.model("small", quality: 55, pricing: .free)],
            preference: 30)
        let config = Fixture.config(accounts: [premium, midrange, local],
                                    logicalModels: [Fixture.logical("x", accounts: [premium, midrange, local])])
        return (config, premium, midrange, local)
    }

    func rank(_ config: DerbyConfig, strategy: RoutingStrategyKind, weights: ScoreWeights = .balanced,
              metric: LatencyMetric = .timeToFirstToken,
              health: [TargetKey: TargetHealth] = [:]) throws -> [String] {
        var c = config
        c.logicalModels[0].policy = RoutingPolicy(strategy: strategy, scoreWeights: weights,
                                                  latencyMetric: metric, deterministic: true)
        let decision = try Router().route(
            RoutingRequest(logicalModelName: "x",
                           requirements: CapabilityRequirements(required: [.text]),
                           promptTokens: 1000),
            snapshot: Fixture.snapshot(c, health: health), randomSeed: 7)
        return decision.plan.attempts.map { $0.target.providerName }
    }

    suite("Strategies / priority") {
        test("priority follows configured order exactly") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .priority), ["Premium", "Midrange", "Local"])
        }
        test("reordering targets changes priority order") {
            var (config, premium, midrange, local) = spread()
            config.logicalModels[0] = Fixture.logical("x", accounts: [local, midrange, premium])
            try expectEqual(try rank(config, strategy: .priority), ["Local", "Midrange", "Premium"])
            _ = (premium, midrange)
        }
        test("failover chain preserves the configured order too") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .failoverChain), ["Premium", "Midrange", "Local"])
        }
    }

    suite("Strategies / weighted score") {
        test("quality-first weighting picks the strongest model") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .weightedScore, weights: .qualityFirst).first, "Premium")
        }
        test("cost-heavy weighting picks the free local model") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .weightedScore, weights: .cheap).first, "Local")
        }
        test("health dominates when a target is degraded") {
            let (config, premium, _, _) = spread()
            var h = TargetHealth(key: TargetKey(providerID: premium.id, modelID: "big"))
            h.state = .unhealthy
            h.errorRate = 0.9
            h.successes = 1
            h.failures = 9
            let weights = ScoreWeights(quality: 0.2, latency: 0, cost: 0, health: 0.8, quota: 0)
            let order = try rank(config, strategy: .weightedScore, weights: weights, health: [h.key: h])
            try expect(order.first != "Premium", "an unhealthy target must not rank first under health weighting")
        }
        test("score components are reported for the inspector") {
            let (config, _, _, _) = spread()
            var c = config
            c.logicalModels[0].policy = RoutingPolicy(strategy: .weightedScore, scoreWeights: .balanced, deterministic: true)
            let decision = try Router().route(
                RoutingRequest(logicalModelName: "x",
                               requirements: CapabilityRequirements(required: [.text]), promptTokens: 1000),
                snapshot: Fixture.snapshot(c))
            let top = try expectNotNil(decision.evaluations.first)
            try expect(!top.components.isEmpty, "weighted score must expose its breakdown")
            try expect(top.components.keys.contains("quality"))
            try expectContains(decision.explanation, "scored highest")
        }
        test("weights are normalized, so their absolute scale does not matter") {
            let (config, _, _, _) = spread()
            let small = ScoreWeights(quality: 0.4, latency: 0.2, cost: 0.1, health: 0.2, quota: 0.1)
            let big = ScoreWeights(quality: 40, latency: 20, cost: 10, health: 20, quota: 10)
            try expectEqual(try rank(config, strategy: .weightedScore, weights: small),
                            try rank(config, strategy: .weightedScore, weights: big))
        }
    }

    suite("Strategies / latency and cost") {
        test("lowest latency prefers the fastest measured target") {
            let (config, premium, midrange, local) = spread()
            func h(_ id: UUID, _ model: String, ttft: Double) -> (TargetKey, TargetHealth) {
                let key = TargetKey(providerID: id, modelID: model)
                var t = TargetHealth(key: key)
                t.ttftP50Seconds = ttft
                t.p50Seconds = ttft
                t.successes = 10
                t.state = .healthy
                return (key, t)
            }
            let health = Dictionary(uniqueKeysWithValues: [
                h(premium.id, "big", ttft: 3.0), h(midrange.id, "mid", ttft: 0.2), h(local.id, "small", ttft: 1.0),
            ])
            try expectEqual(try rank(config, strategy: .lowestLatency, health: health).first, "Midrange")
        }

        test("targets with no samples are tried optimistically, not starved") {
            let (config, premium, midrange, local) = spread()
            let key = TargetKey(providerID: midrange.id, modelID: "mid")
            var slow = TargetHealth(key: key)
            slow.ttftP50Seconds = 9
            slow.successes = 10
            let order = try rank(config, strategy: .lowestLatency, health: [key: slow])
            try expect(order.first != "Midrange", "a measured-slow target should fall behind unmeasured ones")
            _ = (premium, local)
        }

        test("lowest cost prefers free, then cheapest") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .lowestCost), ["Local", "Midrange", "Premium"])
        }

        test("cost multiplier can push a target down the cost ranking") {
            var (config, _, _, _) = spread()
            config.logicalModels[0].targets[1].costMultiplier = 100   // Midrange
            let order = try rank(config, strategy: .lowestCost)
            try expectEqual(order.first, "Local")
            try expect(order.firstIndex(of: "Midrange")! > order.firstIndex(of: "Premium")!)
        }
    }

    suite("Strategies / rotation and locality") {
        test("round robin advances with the cursor") {
            let (config, _, _, _) = spread()
            var c = config
            c.logicalModels[0].policy = RoutingPolicy(strategy: .roundRobin, deterministic: true)
            let snap = Fixture.snapshot(c)
            var firsts: [String] = []
            for cursor in 0..<4 {
                let d = try Router().route(RoutingRequest(logicalModelName: "x",
                                                          requirements: CapabilityRequirements(required: [.text]),
                                                          promptTokens: 10),
                                           snapshot: snap, roundRobinCursor: cursor)
                firsts.append(d.plan.attempts[0].target.providerName)
            }
            try expectEqual(firsts, ["Premium", "Midrange", "Local", "Premium"])
        }

        test("local-first puts local targets ahead of better cloud ones") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .localFirst).first, "Local")
        }

        test("local-first still lists cloud targets as fallback") {
            let (config, _, _, _) = spread()
            let order = try rank(config, strategy: .localFirst)
            try expectEqual(order.count, 3)
            try expect(order.dropFirst().contains("Premium"))
        }

        test("cloud-first pushes local to the back") {
            let (config, _, _, _) = spread()
            try expectEqual(try rank(config, strategy: .cloudFirst).last, "Local")
        }
    }

    suite("Strategies / weighted random") {
        test("weights determine the long-run distribution") {
            let a = Fixture.account("A", models: [Fixture.model("ma")])
            let b = Fixture.account("B", models: [Fixture.model("mb")])
            let lm = Fixture.logical("x", accounts: [a, b], strategy: .weightedRandom, targetWeights: [9, 1])
            var config = Fixture.config(accounts: [a, b], logicalModels: [lm])
            config.logicalModels[0].policy.deterministic = false
            let snap = Fixture.snapshot(config)

            var aWins = 0
            let trials = 400
            for i in 0..<trials {
                let d = try Router().route(RoutingRequest(logicalModelName: "x",
                                                          requirements: CapabilityRequirements(required: [.text]),
                                                          promptTokens: 10),
                                           snapshot: snap, randomSeed: UInt64(i * 7919 + 1))
                if d.plan.attempts[0].target.providerName == "A" { aWins += 1 }
            }
            let share = Double(aWins) / Double(trials)
            try expect(share > 0.8 && share < 0.98, "expected roughly a 90% share for A, got \(share)")
        }

        test("the unpicked targets still form a failover order") {
            let a = Fixture.account("A", models: [Fixture.model("ma")])
            let b = Fixture.account("B", models: [Fixture.model("mb")])
            let c = Fixture.account("C", models: [Fixture.model("mc")])
            let lm = Fixture.logical("x", accounts: [a, b, c], strategy: .weightedRandom, targetWeights: [1, 1, 1])
            let config = Fixture.config(accounts: [a, b, c], logicalModels: [lm])
            let d = try Router().route(RoutingRequest(logicalModelName: "x",
                                                      requirements: CapabilityRequirements(required: [.text]),
                                                      promptTokens: 10),
                                       snapshot: Fixture.snapshot(config), randomSeed: 3)
            try expectEqual(d.plan.attempts.count, 3)
            try expectEqual(Set(d.plan.attempts.map { $0.target.providerName }).count, 3, "no duplicates")
        }

        test("deterministic policies reproduce exactly") {
            let a = Fixture.account("A", models: [Fixture.model("ma")])
            let b = Fixture.account("B", models: [Fixture.model("mb")])
            let lm = Fixture.logical("x", accounts: [a, b], strategy: .weightedRandom, targetWeights: [1, 1])
            let config = Fixture.config(accounts: [a, b], logicalModels: [lm])
            let snap = Fixture.snapshot(config)
            let req = RoutingRequest(logicalModelName: "x",
                                     requirements: CapabilityRequirements(required: [.text]), promptTokens: 10)
            let first = try Router().route(req, snapshot: snap).plan.attempts.map { $0.target.providerName }
            let second = try Router().route(req, snapshot: snap).plan.attempts.map { $0.target.providerName }
            try expectEqual(first, second)
        }
    }

    suite("Strategies / independence") {
        test("each logical model routes under its own policy") {
            let premium = Fixture.account("Premium", models: [
                Fixture.model("big", quality: 95, pricing: Pricing(inputPerMTok: 15, outputPerMTok: 75))])
            let local = Fixture.account("Local", kind: .ollama, models: [
                Fixture.model("small", quality: 55, pricing: .free)])
            let smart = Fixture.logical("smart", accounts: [premium, local],
                                        strategy: .weightedScore, weights: .qualityFirst)
            let cheap = Fixture.logical("cheap", accounts: [premium, local], strategy: .lowestCost)
            let config = Fixture.config(accounts: [premium, local], logicalModels: [smart, cheap])
            let snap = Fixture.snapshot(config)

            let smartPick = try Router().route(RoutingRequest(logicalModelName: "smart",
                                                              requirements: CapabilityRequirements(required: [.text]),
                                                              promptTokens: 10), snapshot: snap)
            let cheapPick = try Router().route(RoutingRequest(logicalModelName: "cheap",
                                                              requirements: CapabilityRequirements(required: [.text]),
                                                              promptTokens: 10), snapshot: snap)
            try expectEqual(smartPick.plan.attempts[0].target.providerName, "Premium")
            try expectEqual(cheapPick.plan.attempts[0].target.providerName, "Local")
            try expectEqual(smartPick.strategy, .weightedScore)
            try expectEqual(cheapPick.strategy, .lowestCost)
        }

        test("every strategy kind is constructible and ranks all targets") {
            let a = Fixture.account("A", models: [Fixture.model("ma")])
            let b = Fixture.account("B", models: [Fixture.model("mb")])
            for kind in RoutingStrategyKind.allCases {
                let lm = Fixture.logical("x", accounts: [a, b], strategy: kind)
                let config = Fixture.config(accounts: [a, b], logicalModels: [lm])
                let d = try Router().route(RoutingRequest(logicalModelName: "x",
                                                          requirements: CapabilityRequirements(required: [.text]),
                                                          promptTokens: 10),
                                           snapshot: Fixture.snapshot(config), randomSeed: 1)
                try expectEqual(d.plan.attempts.count, 2, "strategy \(kind.rawValue) dropped targets")
                try expect(!d.explanation.isEmpty, "strategy \(kind.rawValue) produced no explanation")
            }
        }
    }
}
