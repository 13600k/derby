import Foundation

/// Identifies one physical routing target: an account plus a model on it.
public struct TargetKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var providerID: UUID
    public var modelID: String
    public init(providerID: UUID, modelID: String) {
        self.providerID = providerID; self.modelID = modelID
    }
    public var description: String { "\(providerID.uuidString.prefix(8))/\(modelID)" }
}

public enum HealthState: String, Sendable, Codable, CaseIterable {
    case healthy = "HEALTHY"
    case degraded = "DEGRADED"
    case unhealthy = "UNHEALTHY"
    case disabled = "DISABLED"
    case unknown = "UNKNOWN"

    public var displayName: String { rawValue.capitalized }
    public var isRoutable: Bool { self == .healthy || self == .degraded || self == .unknown }
    /// Multiplier applied to the `health` score dimension.
    public var scoreValue: Double {
        switch self {
        case .healthy: return 1.0
        case .unknown: return 0.75
        case .degraded: return 0.45
        case .unhealthy: return 0.05
        case .disabled: return 0
        }
    }
}

public enum CircuitState: String, Sendable, Codable, CaseIterable {
    case closed = "CLOSED"
    case open = "OPEN"
    case halfOpen = "HALF_OPEN"
    public var displayName: String {
        switch self {
        case .closed: return "Closed"
        case .open: return "Open"
        case .halfOpen: return "Half-open"
        }
    }
}

/// One observation of a completed attempt.
public struct AttemptOutcome: Sendable {
    public var key: TargetKey
    public var success: Bool
    public var failure: FailureKind?
    public var totalSeconds: Double
    public var timeToFirstTokenSeconds: Double?
    public var httpStatus: Int?
    public var usage: CanonicalUsage
    public var costUSD: Double
    public var rateLimit: RateLimitSnapshot?
    public var at: Date

    public init(key: TargetKey, success: Bool, failure: FailureKind? = nil,
                totalSeconds: Double, timeToFirstTokenSeconds: Double? = nil,
                httpStatus: Int? = nil, usage: CanonicalUsage = .zero, costUSD: Double = 0,
                rateLimit: RateLimitSnapshot? = nil, at: Date = Date()) {
        self.key = key; self.success = success; self.failure = failure
        self.totalSeconds = totalSeconds; self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.httpStatus = httpStatus; self.usage = usage; self.costUSD = costUSD
        self.rateLimit = rateLimit; self.at = at
    }
}

/// Immutable health view handed to the router. Copied into a snapshot so the
/// hot path never awaits the registry actor.
public struct TargetHealth: Sendable, Codable {
    public var key: TargetKey
    public var state: HealthState
    public var circuit: CircuitState
    public var successes: Int
    public var failures: Int
    public var consecutiveFailures: Int
    public var errorRate: Double
    public var rate429: Double
    public var rate5xx: Double
    public var p50Seconds: Double?
    public var p95Seconds: Double?
    public var ttftP50Seconds: Double?
    public var ttftP95Seconds: Double?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastFailureKind: FailureKind?
    public var lastFailureMessage: String?
    public var circuitOpenedAt: Date?
    public var circuitReopensAt: Date?
    public var inFlight: Int
    public var rateLimit: RateLimitSnapshot?
    public var requestsToday: Int
    public var costTodayUSD: Double
    public var costMonthUSD: Double

    public init(key: TargetKey) {
        self.key = key
        state = .unknown; circuit = .closed
        successes = 0; failures = 0; consecutiveFailures = 0
        errorRate = 0; rate429 = 0; rate5xx = 0
        inFlight = 0; requestsToday = 0; costTodayUSD = 0; costMonthUSD = 0
    }

    public var totalSamples: Int { successes + failures }
    public var successRate: Double { totalSamples == 0 ? 1 : Double(successes) / Double(totalSamples) }

    public func latency(for metric: LatencyMetric) -> Double? {
        switch metric {
        case .timeToFirstToken: return ttftP50Seconds ?? p50Seconds
        case .p50: return p50Seconds
        case .p95: return p95Seconds
        case .totalDuration: return p50Seconds
        }
    }

    public var summaryLine: String {
        var parts: [String] = [state.displayName]
        if circuit != .closed { parts.append("circuit \(circuit.displayName.lowercased())") }
        if totalSamples > 0 { parts.append(String(format: "%.0f%% success", successRate * 100)) }
        if let p = p50Seconds { parts.append("p50 \(p.msString)") }
        return parts.joined(separator: " · ")
    }
}

/// Owns rolling health statistics, circuit breakers, quota counters and
/// concurrency permits for every target. Single actor so all reliability state
/// mutates in one place.
public actor HealthRegistry {
    private struct Sample {
        var success: Bool
        var failure: FailureKind?
        var total: Double
        var ttft: Double?
        var status: Int?
        var at: Double
    }

    private struct TargetState {
        var samples: [Sample] = []
        var consecutiveFailures = 0
        var consecutiveSuccesses = 0
        var circuit: CircuitState = .closed
        var circuitOpenedAt: Date?
        var circuitReopensAtMono: Double?
        var halfOpenProbes = 0
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var lastFailureKind: FailureKind?
        var lastFailureMessage: String?
        var inFlight = 0
        var rateLimit: RateLimitSnapshot?
        var quota = LocalQuotaCounters()
        var manuallyDisabled = false
    }

    private var states: [TargetKey: TargetState] = [:]
    private var settings: HealthSettings
    /// Per-account in-flight counts, for provider-level concurrency limits.
    private var accountInFlight: [UUID: Int] = [:]
    private var accountLimits: [UUID: Int] = [:]
    private var version: UInt64 = 0

    public init(settings: HealthSettings = .default) {
        self.settings = settings
    }

    public func update(settings: HealthSettings) { self.settings = settings; version &+= 1 }
    public func update(accountLimits: [UUID: Int]) { self.accountLimits = accountLimits }

    // MARK: - Recording

    public func record(_ outcome: AttemptOutcome) {
        var s = states[outcome.key] ?? TargetState()
        let now = Clock.monotonic
        s.samples.append(Sample(success: outcome.success, failure: outcome.failure,
                                total: outcome.totalSeconds, ttft: outcome.timeToFirstTokenSeconds,
                                status: outcome.httpStatus, at: now))
        if s.samples.count > settings.windowSize { s.samples.removeFirst(s.samples.count - settings.windowSize) }

        if let rl = outcome.rateLimit { s.rateLimit = rl }
        s.quota.record(tokens: outcome.usage.totalTokens, costUSD: outcome.costUSD, at: now)

        if outcome.success {
            s.consecutiveFailures = 0
            s.consecutiveSuccesses += 1
            s.lastSuccessAt = outcome.at
            if s.circuit == .halfOpen, s.consecutiveSuccesses >= settings.halfOpenSuccessesToClose {
                s.circuit = .closed
                s.circuitOpenedAt = nil
                s.circuitReopensAtMono = nil
                s.halfOpenProbes = 0
            }
        } else if let kind = outcome.failure, kind.countsAgainstHealth {
            s.consecutiveSuccesses = 0
            s.consecutiveFailures += 1
            s.lastFailureAt = outcome.at
            s.lastFailureKind = kind
            if s.circuit == .halfOpen {
                trip(&s)                       // a failed probe re-opens immediately
            } else if s.circuit == .closed && shouldTrip(s) {
                trip(&s)
            }
        }
        states[outcome.key] = s
        version &+= 1
    }

    public func recordFailureMessage(_ key: TargetKey, message: String) {
        var s = states[key] ?? TargetState()
        s.lastFailureMessage = message
        states[key] = s
    }

    private func shouldTrip(_ s: TargetState) -> Bool {
        if s.consecutiveFailures >= settings.failureThreshold { return true }
        let counted = s.samples.filter { $0.success || ($0.failure?.countsAgainstHealth ?? false) }
        guard counted.count >= settings.minimumSamples else { return false }
        let failures = counted.filter { !$0.success }.count
        return Double(failures) / Double(counted.count) >= settings.errorRateThreshold
    }

    private func trip(_ s: inout TargetState) {
        s.circuit = .open
        s.circuitOpenedAt = Date()
        s.circuitReopensAtMono = Clock.monotonic + settings.openDurationSeconds
        s.halfOpenProbes = 0
    }

    /// Moves circuits from open to half-open when their cooldown has elapsed.
    private func advanceCircuits() {
        let now = Clock.monotonic
        for (k, var s) in states where s.circuit == .open {
            if let reopen = s.circuitReopensAtMono, now >= reopen {
                s.circuit = .halfOpen
                s.consecutiveSuccesses = 0
                s.halfOpenProbes = 0
                states[k] = s
                version &+= 1
            }
        }
    }

    // MARK: - Admission

    public enum Admission: Sendable, Equatable {
        case allowed
        case circuitOpen(reopensIn: Double)
        case atCapacity(inFlight: Int, limit: Int)
        case rateLimited(String)
        case disabled
    }

    /// Whether a request may be sent to a target right now. Called by the
    /// executor immediately before dispatch, so it sees live state rather than
    /// the (slightly stale) routing snapshot.
    public func admit(_ key: TargetKey, accountID: UUID, limits: RateLimitConfig,
                      respectCircuit: Bool, respectQuota: Bool) -> Admission {
        advanceCircuits()
        var s = states[key] ?? TargetState()
        if s.manuallyDisabled { return .disabled }

        if respectCircuit {
            switch s.circuit {
            case .open:
                let remaining = max(0, (s.circuitReopensAtMono ?? 0) - Clock.monotonic)
                return .circuitOpen(reopensIn: remaining)
            case .halfOpen:
                if s.halfOpenProbes >= settings.halfOpenMaxProbes {
                    return .circuitOpen(reopensIn: 0)
                }
            case .closed: break
            }
        }

        let accountUsed = accountInFlight[accountID] ?? 0
        let accountLimit = accountLimits[accountID] ?? limits.maxConcurrentRequests
        if accountLimit > 0 && accountUsed >= accountLimit {
            return .atCapacity(inFlight: accountUsed, limit: accountLimit)
        }

        if respectQuota {
            s.quota.rollIfNeeded()
            if let rpm = limits.requestsPerMinute, rpm > 0, s.quota.requestsInLastMinute() >= rpm {
                return .rateLimited("local limit of \(rpm) requests/min reached")
            }
            if let tpm = limits.tokensPerMinute, tpm > 0, s.quota.tokensInLastMinute() >= tpm {
                return .rateLimited("local limit of \(tpm.formattedTokens) tokens/min reached")
            }
            if let daily = limits.dailyRequestQuota, daily > 0, s.quota.requestsToday >= daily {
                return .rateLimited("daily quota of \(daily) requests reached")
            }
            if let cap = limits.monthlyCostBudgetUSD, cap > 0, s.quota.costMonthUSD >= cap {
                return .rateLimited("monthly budget of \(cap.usdString) reached")
            }
            if let rl = s.rateLimit, rl.isExhausted {
                return .rateLimited("provider reports quota exhausted (\(rl.summary))")
            }
        }
        states[key] = s
        return .allowed
    }

    /// Reserves a slot. Balanced by `release`.
    public func acquire(_ key: TargetKey, accountID: UUID) {
        var s = states[key] ?? TargetState()
        s.inFlight += 1
        if s.circuit == .halfOpen { s.halfOpenProbes += 1 }
        states[key] = s
        accountInFlight[accountID, default: 0] += 1
        version &+= 1
    }

    public func release(_ key: TargetKey, accountID: UUID) {
        if var s = states[key] {
            s.inFlight = max(0, s.inFlight - 1)
            if s.circuit == .halfOpen { s.halfOpenProbes = max(0, s.halfOpenProbes - 1) }
            states[key] = s
        }
        if let v = accountInFlight[accountID] { accountInFlight[accountID] = max(0, v - 1) }
        version &+= 1
    }

    // MARK: - Manual control

    public func setDisabled(_ key: TargetKey, _ disabled: Bool) {
        var s = states[key] ?? TargetState()
        s.manuallyDisabled = disabled
        states[key] = s
        version &+= 1
    }

    public func resetCircuit(_ key: TargetKey) {
        guard var s = states[key] else { return }
        s.circuit = .closed
        s.circuitOpenedAt = nil
        s.circuitReopensAtMono = nil
        s.consecutiveFailures = 0
        s.halfOpenProbes = 0
        states[key] = s
        version &+= 1
    }

    public func reset(_ key: TargetKey? = nil) {
        if let key { states[key] = TargetState() } else { states.removeAll() }
        version &+= 1
    }

    // MARK: - Snapshots

    public var stateVersion: UInt64 { version }

    public func health(for key: TargetKey) -> TargetHealth {
        advanceCircuits()
        return materialize(key, states[key] ?? TargetState())
    }

    public func snapshot() -> [TargetKey: TargetHealth] {
        advanceCircuits()
        var out: [TargetKey: TargetHealth] = [:]
        out.reserveCapacity(states.count)
        for (k, s) in states { out[k] = materialize(k, s) }
        return out
    }

    private func materialize(_ key: TargetKey, _ s: TargetState) -> TargetHealth {
        var h = TargetHealth(key: key)
        let counted = s.samples.filter { $0.success || ($0.failure?.countsAgainstHealth ?? false) }
        h.successes = counted.filter { $0.success }.count
        h.failures = counted.count - h.successes
        h.consecutiveFailures = s.consecutiveFailures
        h.errorRate = counted.isEmpty ? 0 : Double(h.failures) / Double(counted.count)
        if !s.samples.isEmpty {
            h.rate429 = Double(s.samples.filter { $0.failure == .rateLimit }.count) / Double(s.samples.count)
            h.rate5xx = Double(s.samples.filter { ($0.status ?? 0) >= 500 }.count) / Double(s.samples.count)
        }
        let totals = s.samples.filter { $0.success }.map(\.total).sorted()
        h.p50Seconds = percentile(totals, 0.50)
        h.p95Seconds = percentile(totals, 0.95)
        let ttfts = s.samples.compactMap { $0.success ? $0.ttft : nil }.sorted()
        h.ttftP50Seconds = percentile(ttfts, 0.50)
        h.ttftP95Seconds = percentile(ttfts, 0.95)
        h.lastSuccessAt = s.lastSuccessAt
        h.lastFailureAt = s.lastFailureAt
        h.lastFailureKind = s.lastFailureKind
        h.lastFailureMessage = s.lastFailureMessage
        h.circuit = s.circuit
        h.circuitOpenedAt = s.circuitOpenedAt
        if let mono = s.circuitReopensAtMono {
            h.circuitReopensAt = Date().addingTimeInterval(max(0, mono - Clock.monotonic))
        }
        h.inFlight = s.inFlight
        h.rateLimit = s.rateLimit
        var q = s.quota
        q.rollIfNeeded()
        h.requestsToday = q.requestsToday
        h.costTodayUSD = q.costTodayUSD
        h.costMonthUSD = q.costMonthUSD

        h.state = {
            if s.manuallyDisabled { return .disabled }
            if s.circuit == .open { return .unhealthy }
            if counted.isEmpty { return .unknown }
            if s.circuit == .halfOpen { return .degraded }
            if h.errorRate >= settings.errorRateThreshold { return .unhealthy }
            if h.errorRate >= settings.degradedErrorRate { return .degraded }
            return .healthy
        }()
        return h
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let idx = Double(sorted.count - 1) * p
        let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
        let frac = idx - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
}
