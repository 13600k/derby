import Foundation
@testable import DerbyCore

func registerExpiringAllowanceTests() {
    let fiveHours = ProviderUsage.fiveHours

    func window(_ used: Double, resetsIn: Double?, duration: Double = 18_000, scope: String? = nil,
                now: Date) -> ProviderUsage.Window {
        ProviderUsage.Window(id: "w\(duration)\(scope ?? "")", label: ProviderUsage.label(forWindowSeconds: duration),
                             usedFraction: used, duration: duration,
                             resetsAt: resetsIn.map { now.addingTimeInterval($0) }, scope: scope)
    }

    func reading(_ windows: [ProviderUsage.Window], now: Date) throws -> PlanAllowance {
        try expectNotNil(PlanAllowance(usage: ProviderUsage(windows: windows, observedAt: now)))
    }

    suite("Expiring allowance / reading") {
        test("a running window scores by unused share over time left") {
            let now = Date()
            let nearlySpent = try reading([window(0.95, resetsIn: 1200, now: now)], now: now)
            try expectClose(nearlySpent.expiryScore(now: now), 0.4286)
            try expectClose(nearlySpent.secondsLeft(now: now), 1200, tolerance: 2)
            try expectClose(try reading([window(0.10, resetsIn: 7200, now: now)], now: now).expiryScore(now: now), 0.6923)
            try expectClose(try reading([window(0.50, resetsIn: 1200, now: now)], now: now).expiryScore(now: now), 0.8824)
        }

        test("an idle window scores as a fresh one") {
            let now = Date()
            for resetsIn in [nil, fiveHours, -60] as [Double?] {
                let idle = try reading([window(0, resetsIn: resetsIn, now: now)], now: now)
                try expectNil(idle.resetsAt, "idle with reset \(String(describing: resetsIn))")
                try expectClose(idle.expiryScore(now: now), 0.5)
            }
        }

        test("a past reset reads as a fresh window and is no longer spent") {
            let now = Date()
            let stale = PlanAllowance(usedFraction: 1, resetsAt: now.addingTimeInterval(-60),
                                      spentUntil: now.addingTimeInterval(-60),
                                      observedAt: now.addingTimeInterval(-3600))
            try expect(!stale.isSpent(now: now))
            try expectClose(stale.expiryScore(now: now), 0.5)
        }

        test("an exhausted weekly window marks the plan spent") {
            let now = Date()
            let plan = try reading([window(0.2, resetsIn: 3600, now: now),
                                    window(1.0, resetsIn: 86_400, duration: ProviderUsage.week, now: now)], now: now)
            try expect(plan.isSpent(now: now))
            let until = try expectNotNil(plan.spentUntil)
            try expectClose(until.timeIntervalSince(now), 86_400, tolerance: 1)
            try expectEqual(plan.expiryScore(now: now), 0)
        }

        test("a scoped window never marks the plan spent") {
            let now = Date()
            let plan = try reading([window(0.2, resetsIn: 3600, now: now),
                                    window(1.0, resetsIn: 86_400, duration: ProviderUsage.week,
                                           scope: "opus", now: now)], now: now)
            try expect(!plan.isSpent(now: now))
        }

        test("Derby's own count has no plan window") {
            let now = Date()
            let counted = ProviderUsage(source: .counted, windows: [window(0.4, resetsIn: nil, now: now)],
                                        observedAt: now)
            try expectNil(PlanAllowance(usage: counted))
        }

        test("summary names time and share left") {
            let now = Date()
            let running = try reading([window(0.38, resetsIn: 6000, now: now)], now: now).summary(now: now)
            try expectContains(running, "62% left")
            try expectContains(running, "resets in")
            try expectContains(try reading([window(0, resetsIn: nil, now: now)], now: now).summary(now: now),
                               "not started")
        }
    }

    suite("Expiring allowance / snapshot") {
        test("the monitor hands routing each plan's window") {
            let now = Date()
            let plan = Fixture.account("Plan", kind: .chatgptSubscription, models: [Fixture.model("p")])
            let metered = Fixture.account("Metered", models: [Fixture.model("m")])
            let local = Fixture.account("Local", kind: .ollama, models: [Fixture.model("l")])
            let meter = ProviderUsage(windows: [window(0.3, resetsIn: 3600, now: now)], observedAt: now)
            let monitor = UsageMonitor(accounts: { [plan, metered, local] },
                                       fetch: { account, _ in account.id == plan.id ? meter : nil },
                                       tallies: { _ in [:] })
            await monitor.refresh()
            let allowances = await monitor.planAllowances()
            try expectEqual(Set(allowances.keys), [plan.id])
            try expectClose(try expectNotNil(allowances[plan.id]).usedFraction, 0.3)
        }

        test("a local target never carries a plan allowance") {
            let local = Fixture.account("Local", kind: .ollama, models: [Fixture.model("l")])
            var snapshot = Fixture.snapshot(Fixture.config(accounts: [local],
                                                           logicalModels: [Fixture.logical("x", accounts: [local])]))
            snapshot.planAllowances[local.id] = PlanAllowance(usedFraction: 0.1, resetsAt: Date().addingTimeInterval(600))
            let target = try expectNotNil(snapshot.logicalModel(named: "x")?.targets.first)
            try expectNil(snapshot.planAllowance(for: target))
        }
    }

    func route(_ accounts: [ProviderAccount], strategy: RoutingStrategyKind = .expiringAllowance,
               allowances: [UUID: PlanAllowance] = [:], health: [TargetKey: TargetHealth] = [:],
               failover: FailoverConfig = FailoverConfig(maxAttempts: 8),
               weights: ScoreWeights = .balanced, conversationAccount: UUID? = nil) throws -> RoutingDecision {
        var lm = Fixture.logical("x", accounts: accounts, strategy: strategy, weights: weights, failover: failover)
        lm.policy.maxCandidates = 8
        var snapshot = Fixture.snapshot(Fixture.config(accounts: accounts, logicalModels: [lm]), health: health)
        snapshot.planAllowances = allowances
        return try Router().route(RoutingRequest(logicalModelName: "x",
                                                 requirements: CapabilityRequirements(required: [.text]),
                                                 promptTokens: 1000,
                                                 conversationAccount: conversationAccount),
                                  snapshot: snapshot)
    }
    func providers(_ decision: RoutingDecision) -> [String] { decision.plan.attempts.map(\.target.providerName) }
    func plan(_ name: String) -> ProviderAccount {
        Fixture.account(name, kind: .chatgptSubscription, models: [Fixture.model(name.lowercased())])
    }
    func cloud(_ name: String) -> ProviderAccount { Fixture.account(name, models: [Fixture.model(name.lowercased())]) }
    func local(_ name: String = "Local") -> ProviderAccount {
        Fixture.account(name, kind: .ollama, models: [Fixture.model(name.lowercased())])
    }
    func running(_ used: Double, left: Double) -> PlanAllowance {
        PlanAllowance(usedFraction: used, resetsAt: Date().addingTimeInterval(left))
    }

    suite("Expiring allowance / strategy") {
        test("most allowance at risk wins: 5% left in 20 min loses to 90% left in 2 h") {
            let a = plan("A"), b = plan("B")
            let order = providers(try route([a, b], allowances: [a.id: running(0.95, left: 1200),
                                                                 b.id: running(0.10, left: 7200)]))
            try expectEqual(order, ["B", "A"])
        }

        test("half left in 20 min beats 90% left in 2 h") {
            let a = plan("A"), b = plan("B")
            let order = providers(try route([b, a], allowances: [a.id: running(0.50, left: 1200),
                                                                 b.id: running(0.10, left: 7200)]))
            try expectEqual(order.first, "A")
        }

        test("a running window beats an idle one with the same allowance") {
            let idle = plan("Idle"), started = plan("Running")
            let order = providers(try route([idle, started],
                                            allowances: [idle.id: PlanAllowance(usedFraction: 0, resetsAt: nil),
                                                         started.id: running(0, left: 16_200)]))
            try expectEqual(order.first, "Running")
        }

        test("tier order: plans, then unmetered cloud, then local, then spent plans") {
            let spent = plan("Spent"), box = local(), metered = cloud("Metered"), live = plan("Plan")
            let now = Date()
            let order = providers(try route([spent, box, metered, live], allowances: [
                spent.id: PlanAllowance(usedFraction: 0.2, resetsAt: now.addingTimeInterval(3600),
                                        spentUntil: now.addingTimeInterval(86_400)),
                live.id: running(0.5, left: 3600),
            ]))
            try expectEqual(order, ["Plan", "Metered", "Local", "Spent"])
        }

        test("no meter data falls back to configured order then local") {
            try expectEqual(providers(try route([local(), cloud("C1"), cloud("C2")])), ["C1", "C2", "Local"])
        }

        test("a conversation on a spent plan does not pull it ahead of a live copy") {
            let now = Date()
            let sub = Fixture.account("Sub", kind: .chatgptSubscription, models: [Fixture.model("gpt-5.6-sol")])
            let alt = Fixture.account("Alt", kind: .chatgptSubscription, models: [Fixture.model("gpt-5.6-sol")])
            let allowances = [sub.id: PlanAllowance(usedFraction: 1, resetsAt: now.addingTimeInterval(3600),
                                                    spentUntil: now.addingTimeInterval(3600)),
                              alt.id: running(0.3, left: 7200)]
            let decision = try route([sub, alt, cloud("Metered"), local()], allowances: allowances,
                                     failover: FailoverConfig(maxAttempts: 3), conversationAccount: sub.id)
            try expectEqual(providers(decision), ["Alt", "Metered", "Local"])
            try expectContains(decision.explanation, "about to expire")
        }

        test("a spent cloud copy does not jump a local copy for being warm") {
            let spent = Fixture.account("PlanQwen", kind: .qwenSubscription, models: [Fixture.model("qwen3.5-9b")])
            let box = Fixture.account("Local", kind: .ollama, models: [Fixture.model("qwen3.5-9b")])
            let now = Date()
            let decision = try route([spent, cloud("Metered"), box], allowances: [
                spent.id: PlanAllowance(usedFraction: 1, resetsAt: now.addingTimeInterval(3600),
                                        spentUntil: now.addingTimeInterval(3600))])
            try expectEqual(providers(decision), ["Metered", "Local", "PlanQwen"])
        }

        test("equal allowance keeps the configured order") {
            let account = Fixture.account("Plan", kind: .chatgptSubscription,
                                          models: [Fixture.model("zeta"), Fixture.model("alpha")])
            let decision = try route([account], allowances: [account.id: running(0.4, left: 3600)])
            try expectEqual(decision.plan.attempts.map(\.target.modelID), ["zeta", "alpha"])
        }

        test("explanation and notes say why") {
            let a = plan("A")
            let decision = try route([a, local()], allowances: [a.id: running(0.4, left: 3600)])
            try expectContains(try expectNotNil(decision.evaluations.first?.note), "left, resets in")
            try expectContains(decision.explanation, "about to expire")
            try expect(decision.explanation.hasSuffix(")."), "unbalanced: \(decision.explanation)")

            let c1 = cloud("C1")
            var down = TargetHealth(key: TargetKey(providerID: c1.id, modelID: "c1"))
            down.circuit = .open
            let fallback = try route([c1, local()], health: [down.key: down])
            try expectEqual(providers(fallback), ["Local"])
            try expectContains(fallback.explanation, "local fallback")
        }
    }

    suite("Expiring allowance / local slot") {
        let crowded = (1...5).map { cloud("C\($0)") } + [local()]

        test("the last slot goes to local when the cap would cut it") {
            let decision = try route(crowded, failover: FailoverConfig(maxAttempts: 4))
            try expectEqual(providers(decision), ["C1", "C2", "C3", "Local"])
            let c4 = try expectNotNil(decision.exclusions.first { $0.providerName == "C4" })
            try expectEqual(c4.stage, .cap)
            try expectContains(c4.reason, "local fallback")
            try expectContains(try expectNotNil(decision.exclusions.first { $0.providerName == "C5" }).reason,
                               "beyond the 4-attempt limit")
        }

        test("other strategies keep the plain cap") {
            let decision = try route(crowded, strategy: .cloudFirst, failover: FailoverConfig(maxAttempts: 4))
            try expect(!providers(decision).contains("Local"))
        }

        test("one attempt keeps the top target") {
            let decision = try route(crowded, failover: FailoverConfig(enabled: false, maxAttempts: 4))
            try expectEqual(providers(decision), ["C1"])
        }
    }

    suite("Expiring allowance / score weight") {
        test("the weight alone prefers the allowance most at risk") {
            let a = plan("A"), b = plan("B")
            let weights = ScoreWeights(quality: 0, latency: 0, cost: 0, health: 0, quota: 0, priority: 0,
                                       expiringAllowance: 1)
            let decision = try route([a, b], strategy: .weightedScore,
                                     allowances: [a.id: running(0.95, left: 1200), b.id: running(0.10, left: 7200)],
                                     weights: weights)
            try expectEqual(providers(decision).first, "B")
            try expect(try expectNotNil(decision.evaluations.first).components.keys.contains("expiringAllowance"))
        }

        test("weights saved before the dimension decode with it off") {
            let old = try JSONDecoder().decode(ScoreWeights.self, from: Data(#"{"quality":0.35}"#.utf8))
            try expectEqual(old.expiringAllowance, 0)
            let saved = try JSONEncoder().encode(ScoreWeights(expiringAllowance: 0.4))
            try expectEqual(try JSONDecoder().decode(ScoreWeights.self, from: saved).expiringAllowance, 0.4)
        }

        test("a target with no plan window scores zero on the dimension") {
            let box = local()
            let snapshot = Fixture.snapshot(Fixture.config(accounts: [box],
                                                           logicalModels: [Fixture.logical("x", accounts: [box])]))
            let target = try expectNotNil(snapshot.logicalModel(named: "x")?.targets.first)
            let d = TargetScorer().dimensions(for: target, health: TargetHealth(key: target.key),
                                              metric: .timeToFirstToken, candidateCount: 1, promptTokens: 100)
            try expectEqual(d.expiringAllowance, 0)
        }
    }
}
