import Foundation

/// The one part of a plan meter routing reads: how much of an account's short
/// window is left, and how long there is to spend it.
///
/// Allowance still unspent when a window resets is lost, so the allowance most
/// at risk is the one that would have to be spent fastest to use it all:
/// `unused ÷ time left`. `expiryScore` is that rate mapped onto 0…1, which the
/// `expiring_allowance` strategy sorts by and the score weight of the same
/// name reads. Nearly spent and about to reset loses to plenty left with hours
/// to go, because the first would only meet a 429 for its last few percent.
///
/// Built from the dashboard's last good reading and carried to the router in
/// the snapshot, never fetched on the request path. A window that is idle, or
/// whose reset has passed since it was read, counts as a fresh one: the next
/// request starts it. The sliding reset an idle meter reports is never read,
/// so the ranking cannot flap between polls.
public struct PlanAllowance: Sendable, Hashable {
    /// Length of the window, in seconds.
    public var duration: Double
    /// 0 = untouched, 1 = spent, as of `observedAt`.
    public var usedFraction: Double
    /// When the running window resets. Nil when it is idle or unstated.
    public var resetsAt: Date?
    /// An account-wide window — the weekly cap as well — is exhausted until
    /// then. Per-model caps never set it: their scope cannot be matched to a
    /// target's model reliably.
    public var spentUntil: Date?
    public var observedAt: Date

    public init(duration: Double = ProviderUsage.fiveHours, usedFraction: Double, resetsAt: Date?,
                spentUntil: Date? = nil, observedAt: Date = Date()) {
        self.duration = max(1, duration)
        self.usedFraction = min(1, max(0, usedFraction))
        self.resetsAt = resetsAt
        self.spentUntil = spentUntil
        self.observedAt = observedAt
    }

    /// Nil unless the provider's own meter reports a short account-wide
    /// window (`PlanWarmUp.sessionWindow`): Derby's own count cannot see the
    /// provider's clock, and a metered API has no window at all.
    public init?(usage: ProviderUsage) {
        guard let window = PlanWarmUp.sessionWindow(usage) else { return nil }
        let duration = window.duration ?? ProviderUsage.fiveHours
        let idle = PlanWarmUp.isIdle(window, observedAt: usage.observedAt)
        let spent = usage.windows
            .filter { $0.scope == nil && $0.isExhausted }
            .map { $0.resetsAt ?? usage.observedAt.addingTimeInterval($0.duration ?? duration) }
            .max()
        self.init(duration: duration, usedFraction: window.usedFraction ?? 0,
                  resetsAt: idle ? nil : window.resetsAt, spentUntil: spent, observedAt: usage.observedAt)
    }

    public func isSpent(now: Date) -> Bool {
        spentUntil.map { $0 > now } ?? false
    }

    /// Whether the window the reading describes is still the one running.
    private func isRunning(now: Date) -> Bool {
        resetsAt.map { $0 > now } ?? false
    }

    public func secondsLeft(now: Date) -> Double {
        guard isRunning(now: now), let resetsAt else { return duration }
        return min(duration, resetsAt.timeIntervalSince(now))
    }

    /// Share of the window still to spend. A reset since the reading means
    /// the whole of a fresh window.
    public func unused(now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 1 }
        return 1 - usedFraction
    }

    /// `unused ÷ time left` mapped onto 0…1: a fresh window scores 0.5, one
    /// with allowance left and little time to spend it approaches 1, and a
    /// spent plan scores 0.
    public func expiryScore(now: Date) -> Double {
        guard !isSpent(now: now) else { return 0 }
        let unused = unused(now: now)
        let timeShare = secondsLeft(now: now) / duration
        guard unused + timeShare > 0 else { return 0 }
        return unused / (unused + timeShare)
    }

    /// One line for routing notes: "5-hour: 62% left, resets in 1h 40m".
    public func summary(now: Date) -> String {
        let label = ProviderUsage.label(forWindowSeconds: duration)
        if isSpent(now: now), let spentUntil {
            let soon = spentUntil.timeIntervalSince(now) < 20 * 3600
            return "plan spent until \(spentUntil.formatted(date: soon ? .omitted : .abbreviated, time: .shortened))"
        }
        guard isRunning(now: now) else { return "\(label) window not started" }
        let left = Int((unused(now: now) * 100).rounded())
        return "\(label): \(left)% left, resets in \(Self.compact(secondsLeft(now: now)))"
    }

    static func compact(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes < 1 { return "under a minute" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
