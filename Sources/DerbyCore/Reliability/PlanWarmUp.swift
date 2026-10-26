import Foundation

/// Keeps a subscription's short usage window running.
///
/// Claude and ChatGPT plans meter a rolling five-hour window that starts with
/// the first request, not on a fixed clock. Left alone, it starts whenever the
/// user does, so the allowance comes back five hours after they began. Started
/// by Derby whenever it is idle, it is always somewhere in its cycle and
/// resets sooner. One request that answers "ok" is enough, and that is all a
/// warm-up spends.
///
/// The decision is the hard part, and it is pure so it can be tested:
/// **idle means the clock is not running, not that nothing is used.** A
/// warm-up rounds to 0%, so "0% used" alone would send one every poll forever.
/// A running window has a fixed reset in the future. An idle one has none,
/// one in the past, or one a whole window from now that moves forward with
/// every read — the three ways a meter can say "nothing started yet".
///
/// `UsageMonitor` does the sending; nothing here is on the request path, and
/// the router never reads it.
public enum PlanWarmUp {
    /// A reset within this much of a full window away has not started: either
    /// the meter reports an idle window as starting now, or it started in the
    /// last half minute and a warm-up is redundant but harmless. Shorter than
    /// the monitor's tick, so the read that verifies a warm-up sees it running.
    public static let idleSlack: Double = 30

    /// What a warm-up sent and what it cost.
    public struct Receipt: Sendable, Hashable {
        public var model: String
        public var usage: CanonicalUsage
        public init(model: String, usage: CanonicalUsage) { self.model = model; self.usage = usage }
    }

    /// The provider's own account-wide window shorter than a day: the
    /// five-hour window on both plans today. Per-model windows (`scope`) and
    /// Derby's own count, which cannot see the provider's clock, have none.
    public static func sessionWindow(_ usage: ProviderUsage) -> ProviderUsage.Window? {
        guard usage.source == .provider else { return nil }
        return usage.windows
            .filter { $0.scope == nil && ($0.duration ?? .infinity) < ProviderUsage.day }
            .min { ($0.duration ?? 0) < ($1.duration ?? 0) }
    }

    /// Whether the window's clock has yet to start, as of the meter's reading.
    public static func isIdle(_ window: ProviderUsage.Window, observedAt: Date) -> Bool {
        guard let used = window.usedFraction, used <= 0 else { return false }
        guard let resets = window.resetsAt else { return true }
        if resets <= observedAt { return true }
        guard let duration = window.duration else { return false }
        return resets.timeIntervalSince(observedAt) >= duration - idleSlack
    }

    /// Whether to start the window now. `lastWarmedAt` is when Derby last
    /// started it: the window that began then is still running for one window
    /// length, whatever the meter says, which is what keeps a meter that reads
    /// idle after a warm-up from turning into a loop.
    public static func shouldWarm(_ usage: ProviderUsage, lastWarmedAt: Date?, now: Date) -> Bool {
        guard !usage.isLimited, let window = sessionWindow(usage),
              isIdle(window, observedAt: usage.observedAt) else { return false }
        if let last = lastWarmedAt, now.timeIntervalSince(last) < (window.duration ?? ProviderUsage.fiveHours) {
            return false
        }
        return true
    }

    /// The smallest request that counts: one short question, a short answer
    /// and no reasoning. Adapters drop whatever an endpoint would reject.
    public static func request(modelID: String) -> CanonicalRequest {
        var request = CanonicalRequest(requestedModel: modelID)
        request.messages = [.user("Reply with the single word: ok")]
        request.maxOutputTokens = 16
        return request
    }
}
