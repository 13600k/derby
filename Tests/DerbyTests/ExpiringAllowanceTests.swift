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
}
