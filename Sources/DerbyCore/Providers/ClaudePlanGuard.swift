import Foundation

/// Which allowance paid for a Claude subscription request, as its response
/// says.
///
/// Every answer to a subscription login carries Anthropic's
/// `anthropic-ratelimit-unified-*` headers. The names and the reading below are
/// the Claude Code CLI's own (2.1.310): a request was paid from extra usage —
/// pay-as-you-go past the plan — when `overage-in-use` is true, or when the
/// plan refused it (`status: rejected`) and overage let it through.
public enum PlanLane: Sendable, Equatable {
    /// The plan paid. Utilizations are fractions of each window, when stated.
    case plan(fiveHour: Double?, sevenDay: Double?)
    /// Extra usage paid; the plan's window resets at `resetsAt`, when stated.
    case extraUsage(resetsAt: Date?)
    /// No unified headers at all, so nothing shows the plan paid.
    case unknown

    static let prefix = "anthropic-ratelimit-unified-"

    public static func parse(_ headers: [String: String]) -> PlanLane {
        func value(_ name: String) -> String? {
            headers[prefix + name]?.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let status = value("status") else { return .unknown }
        let overage = value("overage-status")
        let overageAllowed = overage == "allowed" || overage == "allowed_warning"
        if value("overage-in-use") == "true" || (status == "rejected" && overageAllowed) {
            let reset = ["reset", "5h-reset", "7d-reset"].lazy
                .compactMap { UsageTime.date(value($0).map(JSONValue.string)) }.first
            return .extraUsage(resetsAt: reset)
        }
        return .plan(fiveHour: value("5h-utilization").flatMap(Double.init),
                     sevenDay: value("7d-utilization").flatMap(Double.init))
    }
}

/// Keeps a Claude subscription on its plan.
///
/// A request Anthropic does not count as Claude Code is billed to extra usage,
/// and so is one sent after the plan's window is spent, if the account has
/// extra usage turned on. Turning it off at claude.ai/settings/usage is the
/// only hard guarantee — Anthropic then refuses such a request instead. This is
/// the second line: the first answer the plan did not pay for holds the account
/// out of routing until the plan resets, and every request to it until then
/// fails in a millisecond, which the executor treats as an exhausted allowance
/// and fails over from. A stream is checked on its headers, before any of it is
/// read, so one that would bill is dropped before the client sees a byte.
public actor ClaudePlanGuard {
    public static let shared = ClaudePlanGuard()

    public struct Hold: Sendable, Equatable {
        public var until: Date
        public var reason: String
        public init(until: Date, reason: String) { self.until = until; self.reason = reason }
    }

    /// How long an account is held when the response names no reset.
    static let defaultHold: Double = 3600

    private var holds: [UUID: Hold] = [:]

    public init() {}

    /// The hold on an account, while it lasts.
    public func hold(for account: UUID, now: Date = Date()) -> Hold? {
        guard let hold = holds[account] else { return nil }
        guard hold.until > now else {
            holds[account] = nil
            return nil
        }
        return hold
    }

    /// Records what a successful response says about who paid for it, and
    /// returns the hold it placed, if it placed one.
    @discardableResult
    public func observe(_ headers: [String: String], account: ProviderAccount, now: Date = Date()) -> Hold? {
        let hold: Hold
        switch PlanLane.parse(headers) {
        case .plan:
            return nil
        case .extraUsage(let resetsAt):
            let until = resetsAt.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(Self.defaultHold)
            hold = Hold(until: until, reason: "Anthropic billed a request on \(account.name) to extra usage, not the plan")
        case .unknown:
            // Fail closed: a request the plan cannot be shown to have paid for
            // is treated as one it did not.
            hold = Hold(until: now.addingTimeInterval(Self.defaultHold),
                        reason: "Anthropic's answer on \(account.name) did not show the plan paying for it")
        }
        if let existing = holds[account.id], existing.until > hold.until { return existing }
        holds[account.id] = hold
        DerbyLog.warn("plan-guard", "\(hold.reason); holding it out of routing until \(hold.until.formatted(date: .abbreviated, time: .shortened)).")
        return hold
    }

    /// What a request to a held account fails with.
    public static func error(for hold: Hold, now: Date = Date()) -> DerbyError {
        DerbyError(kind: .quotaExhausted,
                   message: "\(hold.reason). Derby is sending nothing more through it until \(hold.until.formatted(date: .abbreviated, time: .shortened)), so nothing else is billed past the plan. Turn extra usage off at claude.ai/settings/usage, or allow it for this account in Providers.",
                   retryAfter: max(0, hold.until.timeIntervalSince(now)))
    }
}
