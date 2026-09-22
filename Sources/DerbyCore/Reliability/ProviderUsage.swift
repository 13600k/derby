import Foundation

/// How much of an account's allowance is spent: the rolling windows a plan
/// meters (five hours, a week), per-model caps inside them, and any balance.
///
/// Two sources, never mixed in one report. A provider that publishes its
/// meter is asked (`ProviderAdapter.usage`); one that does not — Qwen Cloud's
/// Coding Plan answers only a signed-in console, never an API key — gets
/// Derby's own count of what it routed there, labelled as such, because a
/// count that misses traffic sent from elsewhere is still better than nothing
/// as long as it never passes for the provider's figure.
///
/// Display only: the router does not read it.
public struct ProviderUsage: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        /// The provider's own meter.
        case provider
        /// Successful requests Derby routed to the account, over rolling windows.
        case counted
    }

    public enum Unit: Sendable, Hashable {
        case requests
        case usd
        case credits
        /// A currency the provider named, e.g. "CNY".
        case currency(String)
    }

    /// One metered window.
    public struct Window: Sendable, Hashable, Identifiable {
        /// Stable across polls, so the UI can key on it.
        public var id: String
        public var label: String
        /// 0 = untouched, 1 = spent. Nil when no limit is known, which only a
        /// counted window without a declared limit can be.
        public var usedFraction: Double?
        public var used: Double?
        public var limit: Double?
        public var unit: Unit?
        /// Length of the window in seconds, when known.
        public var duration: Double?
        public var resetsAt: Date?
        /// The provider says this window is what is blocking requests now.
        public var isLimiting: Bool

        public init(id: String, label: String, usedFraction: Double? = nil, used: Double? = nil,
                    limit: Double? = nil, unit: Unit? = nil, duration: Double? = nil,
                    resetsAt: Date? = nil, isLimiting: Bool = false) {
            self.id = id; self.label = label
            self.usedFraction = usedFraction.map { min(1, max(0, $0)) }
            self.used = used; self.limit = limit; self.unit = unit
            self.duration = duration; self.resetsAt = resetsAt; self.isLimiting = isLimiting
        }

        public var isExhausted: Bool { isLimiting || (usedFraction ?? 0) >= 1 }
    }

    /// A figure with no limit attached: a balance, or what was spent so far.
    public struct Amount: Sendable, Hashable, Identifiable {
        public var id: String { label }
        public var label: String
        public var value: Double
        public var unit: Unit
        public init(label: String, value: Double, unit: Unit) {
            self.label = label; self.value = value; self.unit = unit
        }
    }

    public var source: Source
    /// The plan the provider says the account is on, when it says.
    public var plan: String?
    public var windows: [Window]
    public var amounts: [Amount]
    /// The provider's own verdict, which can be stated without any window
    /// being full (a balance that ran dry, a model-level cap).
    public var providerSaysLimited: Bool
    public var observedAt: Date

    public init(source: Source = .provider, plan: String? = nil, windows: [Window] = [],
                amounts: [Amount] = [], providerSaysLimited: Bool = false, observedAt: Date = Date()) {
        self.source = source; self.plan = plan; self.windows = windows; self.amounts = amounts
        self.providerSaysLimited = providerSaysLimited; self.observedAt = observedAt
    }

    public var isEmpty: Bool { windows.isEmpty && amounts.isEmpty && plan == nil }
    public var isLimited: Bool { providerSaysLimited || windows.contains(where: \.isExhausted) }

    /// The fullest window, for a one-line summary.
    public var tightestWindow: Window? {
        windows.filter { $0.usedFraction != nil }.max { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }
    }

    /// One line for logs: "5-hour 38% · Weekly 21%".
    public var summary: String {
        var parts = windows.map { w -> String in
            if let f = w.usedFraction { return "\(w.label) \(Int((f * 100).rounded()))%" }
            return "\(w.label) \(Int(w.used ?? 0)) req"
        }
        parts += amounts.map { "\($0.label) \(String(format: "%.2f", $0.value))" }
        if let plan { parts.insert(plan, at: 0) }
        return parts.isEmpty ? "nothing reported" : parts.joined(separator: " · ")
    }

    // MARK: - Window naming

    public static let fiveHours: Double = 5 * 3600
    public static let day: Double = 86_400
    public static let week: Double = 7 * 86_400

    /// Names a window by its length, never by its position in a payload: the
    /// ChatGPT backend puts a weekly-only plan's one window in the slot a
    /// five-hour window usually occupies.
    public static func label(forWindowSeconds seconds: Double) -> String {
        let hours = seconds / 3600
        switch hours {
        case 4.5..<5.5: return "5-hour"
        case 23..<25: return "Daily"
        case (7 * 24 - 2)..<(7 * 24 + 2): return "Weekly"
        case (28 * 24)..<(32 * 24): return "Monthly"
        case ..<48: return "\(Int(hours.rounded()))-hour"
        default: return "\(Int((hours / 24).rounded()))-day"
        }
    }

    // MARK: - Counted fallback

    /// Requests and tokens Derby sent one account over one window.
    public struct Tally: Sendable, Hashable {
        public var requests: Int
        public var tokens: Int
        public init(requests: Int = 0, tokens: Int = 0) { self.requests = requests; self.tokens = tokens }
    }

    /// Windows Derby counts for an account whose provider reports nothing.
    public static let countedWindows: [(id: String, label: String, seconds: Double)] = [
        ("counted.5h", "5-hour", fiveHours),
        ("counted.7d", "7-day", week),
        ("counted.30d", "30-day", 30 * day),
    ]

    /// The limit, if any, the account declared for one counted window.
    static func declaredLimit(_ id: String, _ limits: RateLimitConfig) -> Int? {
        switch id {
        case "counted.5h": return limits.planRequestsPer5Hours
        case "counted.7d": return limits.planRequestsPerWeek
        case "counted.30d": return limits.planRequestsPerMonth
        default: return nil
        }
    }

    /// Derby's own count, against whatever limits the account declared.
    ///
    /// Nil when there is nothing to say — no traffic and no declared limit —
    /// so an idle metered key does not grow an empty meter. The 30-day window
    /// only appears when a monthly limit was declared: plans that meter a
    /// month (Qwen Cloud's Coding Plan does) are the only reason to show it.
    public static func counted(tallies: [String: Tally], limits: RateLimitConfig,
                               now: Date = Date()) -> ProviderUsage? {
        var windows: [Window] = []
        for spec in countedWindows {
            let tally = tallies[spec.id] ?? Tally()
            let limit = declaredLimit(spec.id, limits).flatMap { $0 > 0 ? $0 : nil }
            if spec.id == "counted.30d" && limit == nil { continue }
            windows.append(Window(id: spec.id, label: spec.label,
                                  usedFraction: limit.map { Double(tally.requests) / Double($0) },
                                  used: Double(tally.requests),
                                  limit: limit.map(Double.init),
                                  unit: .requests,
                                  duration: spec.seconds))
        }
        let anyTraffic = windows.contains { ($0.used ?? 0) > 0 }
        let anyLimit = windows.contains { $0.limit != nil }
        guard anyTraffic || anyLimit else { return nil }
        return ProviderUsage(source: .counted, windows: windows, observedAt: now)
    }
}

/// What the dashboard shows for one account: the last usage that could be
/// read, and why the latest attempt failed if it did.
public struct ProviderUsageStatus: Sendable, Hashable {
    public var usage: ProviderUsage?
    /// Set when the most recent poll failed; `usage` is then the last good
    /// report (or Derby's count, if the provider never answered).
    public var error: String?
    public var attemptedAt: Date?

    public init(usage: ProviderUsage? = nil, error: String? = nil, attemptedAt: Date? = nil) {
        self.usage = usage; self.error = error; self.attemptedAt = attemptedAt
    }
}
