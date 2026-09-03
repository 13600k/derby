import Foundation

/// Rate-limit state observed from provider response headers.
public struct RateLimitSnapshot: Sendable, Hashable, Codable {
    public var requestsLimit: Int?
    public var requestsRemaining: Int?
    public var requestsResetSeconds: Double?
    public var tokensLimit: Int?
    public var tokensRemaining: Int?
    public var tokensResetSeconds: Double?
    public var retryAfterSeconds: Double?
    public var observedAt: Date

    public init(requestsLimit: Int? = nil, requestsRemaining: Int? = nil, requestsResetSeconds: Double? = nil,
                tokensLimit: Int? = nil, tokensRemaining: Int? = nil, tokensResetSeconds: Double? = nil,
                retryAfterSeconds: Double? = nil, observedAt: Date = Date()) {
        self.requestsLimit = requestsLimit
        self.requestsRemaining = requestsRemaining
        self.requestsResetSeconds = requestsResetSeconds
        self.tokensLimit = tokensLimit
        self.tokensRemaining = tokensRemaining
        self.tokensResetSeconds = tokensResetSeconds
        self.retryAfterSeconds = retryAfterSeconds
        self.observedAt = observedAt
    }

    public var isEmpty: Bool {
        requestsLimit == nil && requestsRemaining == nil && tokensLimit == nil
            && tokensRemaining == nil && retryAfterSeconds == nil
    }

    /// 0 = plenty of headroom, 1 = exhausted. Feeds the `quota` score dimension.
    public var pressure: Double {
        var worst = 0.0
        if let lim = requestsLimit, lim > 0, let rem = requestsRemaining {
            worst = max(worst, 1 - Double(max(0, rem)) / Double(lim))
        }
        if let lim = tokensLimit, lim > 0, let rem = tokensRemaining {
            worst = max(worst, 1 - Double(max(0, rem)) / Double(lim))
        }
        // A live Retry-After means we are already limited.
        if let ra = retryAfterSeconds, ra > 0, Date().timeIntervalSince(observedAt) < ra { worst = 1 }
        return min(1, max(0, worst))
    }

    /// True when the provider has told us there is nothing left right now.
    public var isExhausted: Bool {
        if let r = requestsRemaining, r <= 0, !hasReset(requestsResetSeconds) { return true }
        if let t = tokensRemaining, t <= 0, !hasReset(tokensResetSeconds) { return true }
        if let ra = retryAfterSeconds, Date().timeIntervalSince(observedAt) < ra { return true }
        return false
    }

    private func hasReset(_ resetIn: Double?) -> Bool {
        guard let resetIn else { return false }
        return Date().timeIntervalSince(observedAt) >= resetIn
    }

    public var summary: String {
        var parts: [String] = []
        if let rem = requestsRemaining, let lim = requestsLimit { parts.append("\(rem)/\(lim) req") }
        else if let rem = requestsRemaining { parts.append("\(rem) req left") }
        if let rem = tokensRemaining, let lim = tokensLimit {
            parts.append("\(rem.formattedTokens)/\(lim.formattedTokens) tok")
        }
        if let ra = retryAfterSeconds { parts.append("retry after \(Int(ra))s") }
        return parts.isEmpty ? "no limit headers" : parts.joined(separator: " · ")
    }

    /// Parses the header conventions used by OpenAI, Anthropic and most
    /// OpenAI-compatible gateways.
    public static func parseStandardHeaders(_ h: [String: String]) -> RateLimitSnapshot? {
        func int(_ keys: [String]) -> Int? {
            for k in keys { if let v = h[k], let i = Int(v.trimmingCharacters(in: .whitespaces)) { return i } }
            return nil
        }
        func duration(_ keys: [String]) -> Double? {
            for k in keys {
                guard let v = h[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { continue }
                if let d = parseDuration(v) { return d }
                if let date = parseHTTPDate(v) { return max(0, date.timeIntervalSinceNow) }
            }
            return nil
        }

        let snap = RateLimitSnapshot(
            requestsLimit: int(["x-ratelimit-limit-requests", "anthropic-ratelimit-requests-limit",
                                "ratelimit-limit", "x-ratelimit-limit"]),
            requestsRemaining: int(["x-ratelimit-remaining-requests", "anthropic-ratelimit-requests-remaining",
                                    "ratelimit-remaining", "x-ratelimit-remaining"]),
            requestsResetSeconds: duration(["x-ratelimit-reset-requests", "anthropic-ratelimit-requests-reset",
                                            "ratelimit-reset", "x-ratelimit-reset"]),
            tokensLimit: int(["x-ratelimit-limit-tokens", "anthropic-ratelimit-tokens-limit",
                              "anthropic-ratelimit-input-tokens-limit"]),
            tokensRemaining: int(["x-ratelimit-remaining-tokens", "anthropic-ratelimit-tokens-remaining",
                                  "anthropic-ratelimit-input-tokens-remaining"]),
            tokensResetSeconds: duration(["x-ratelimit-reset-tokens", "anthropic-ratelimit-tokens-reset"]),
            retryAfterSeconds: duration(["retry-after", "x-should-retry-after"])
        )
        return snap.isEmpty ? nil : snap
    }

    /// Handles "3", "1.5s", "6m0s", "250ms", "1h30m".
    public static func parseDuration(_ s: String) -> Double? {
        if let plain = Double(s) { return plain }
        var total = 0.0
        var number = ""
        var matched = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber || c == "." {
                number.append(c)
                i = s.index(after: i)
                continue
            }
            var unit = String(c)
            let next = s.index(after: i)
            if unit == "m", next < s.endIndex, s[next] == "s" {
                unit = "ms"
                i = next
            }
            guard let v = Double(number) else { return matched ? total : nil }
            switch unit {
            case "h": total += v * 3600
            case "m": total += v * 60
            case "s": total += v
            case "ms": total += v / 1000
            default: return matched ? total : nil
            }
            matched = true
            number = ""
            i = s.index(after: i)
        }
        if !number.isEmpty, let v = Double(number) { total += v; matched = true }
        return matched ? total : nil
    }

    private static let httpDateFormatters: [DateFormatter] = {
        let patterns = ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = p
            return f
        }
    }()

    public static func parseHTTPDate(_ s: String) -> Date? {
        for f in httpDateFormatters { if let d = f.date(from: s) { return d } }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// Client-side counters for limits Derby enforces itself (the user's declared
/// RPM/TPM and daily quota), independent of provider headers.
public struct LocalQuotaCounters: Sendable {
    public var requestTimestamps: [Double] = []      // monotonic seconds
    public var tokenEvents: [(at: Double, tokens: Int)] = []
    public var requestsToday: Int = 0
    public var costTodayUSD: Double = 0
    public var costMonthUSD: Double = 0
    public var dayKey: String = ""
    public var monthKey: String = ""

    public init() {}

    public mutating func rollIfNeeded(now: Date = Date()) {
        let day = LocalQuotaCounters.dayFormatter.string(from: now)
        let month = String(day.prefix(7))
        if dayKey != day { dayKey = day; requestsToday = 0; costTodayUSD = 0 }
        if monthKey != month { monthKey = month; costMonthUSD = 0 }
    }

    public mutating func record(tokens: Int, costUSD: Double, at now: Double = Clock.monotonic) {
        rollIfNeeded()
        requestTimestamps.append(now)
        tokenEvents.append((now, tokens))
        requestsToday += 1
        costTodayUSD += costUSD
        costMonthUSD += costUSD
        trim(now: now)
    }

    public mutating func trim(now: Double = Clock.monotonic) {
        let cutoff = now - 60
        requestTimestamps.removeAll { $0 < cutoff }
        tokenEvents.removeAll { $0.at < cutoff }
    }

    public func requestsInLastMinute(now: Double = Clock.monotonic) -> Int {
        requestTimestamps.filter { $0 >= now - 60 }.count
    }
    public func tokensInLastMinute(now: Double = Clock.monotonic) -> Int {
        tokenEvents.filter { $0.at >= now - 60 }.reduce(0) { $0 + $1.tokens }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
