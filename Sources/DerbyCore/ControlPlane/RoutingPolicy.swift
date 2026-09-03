import Foundation

/// Selection algorithms. Adding one means adding a case here plus a
/// `RoutingStrategy` implementation — nothing in the executor changes.
public enum RoutingStrategyKind: String, Codable, Sendable, CaseIterable, Hashable {
    case priority
    case weightedRandom = "weighted_random"
    case weightedScore = "weighted_score"
    case lowestLatency = "lowest_latency"
    case lowestCost = "lowest_cost"
    case roundRobin = "round_robin"
    case failoverChain = "failover_chain"
    case localFirst = "local_first"
    case cloudFirst = "cloud_first"

    public var displayName: String {
        switch self {
        case .priority: return "Priority"
        case .weightedRandom: return "Weighted Random"
        case .weightedScore: return "Weighted Score"
        case .lowestLatency: return "Lowest Latency"
        case .lowestCost: return "Lowest Cost"
        case .roundRobin: return "Round Robin"
        case .failoverChain: return "Failover Chain"
        case .localFirst: return "Local First"
        case .cloudFirst: return "Cloud First"
        }
    }

    public var summary: String {
        switch self {
        case .priority: return "Always try targets in the order you arranged them."
        case .weightedRandom: return "Split traffic across targets by weight."
        case .weightedScore: return "Rank targets by a weighted blend of quality, latency, cost, health and spare quota."
        case .lowestLatency: return "Prefer whichever target has been answering fastest."
        case .lowestCost: return "Prefer the cheapest eligible target."
        case .roundRobin: return "Spread requests evenly across equivalent targets."
        case .failoverChain: return "A strict chain: each target is only used when the ones above it fail."
        case .localFirst: return "Use local models when they are healthy; fall back to the cloud."
        case .cloudFirst: return "Use cloud models first; fall back to local models in an emergency."
        }
    }

    /// Whether the strategy consumes the per-target `weight` field.
    public var usesWeights: Bool { self == .weightedRandom }
    /// Whether the strategy consumes `ScoreWeights`.
    public var usesScoreWeights: Bool { self == .weightedScore }
}

/// Weights for the `weighted_score` strategy. Normalized at use time, so the
/// UI can present them as sliders that need not sum to 1.
public struct ScoreWeights: Codable, Sendable, Hashable {
    public var quality: Double
    public var latency: Double
    public var cost: Double
    public var health: Double
    public var quota: Double
    public var priority: Double
    public var providerPreference: Double
    public var localPreference: Double
    public var contextHeadroom: Double

    public init(quality: Double = 0.35, latency: Double = 0.20, cost: Double = 0.10,
                health: Double = 0.20, quota: Double = 0.10, priority: Double = 0.05,
                providerPreference: Double = 0, localPreference: Double = 0,
                contextHeadroom: Double = 0) {
        self.quality = quality; self.latency = latency; self.cost = cost
        self.health = health; self.quota = quota; self.priority = priority
        self.providerPreference = providerPreference
        self.localPreference = localPreference
        self.contextHeadroom = contextHeadroom
    }

    public static let balanced = ScoreWeights()
    public static let qualityFirst = ScoreWeights(quality: 0.55, latency: 0.10, cost: 0.05, health: 0.20, quota: 0.10)
    public static let cheap = ScoreWeights(quality: 0.10, latency: 0.10, cost: 0.55, health: 0.15, quota: 0.10)
    public static let fast = ScoreWeights(quality: 0.15, latency: 0.55, cost: 0.05, health: 0.20, quota: 0.05)

    public var dimensions: [(name: String, key: WritableKeyPath<ScoreWeights, Double>)] {
        [("Quality", \.quality), ("Latency", \.latency), ("Cost", \.cost),
         ("Health", \.health), ("Spare quota", \.quota), ("Priority", \.priority),
         ("Provider preference", \.providerPreference), ("Local preference", \.localPreference),
         ("Context headroom", \.contextHeadroom)]
    }

    public var total: Double {
        max(0.0001, quality + latency + cost + health + quota + priority
            + providerPreference + localPreference + contextHeadroom)
    }
    public var normalized: ScoreWeights {
        let t = total
        return ScoreWeights(quality: quality / t, latency: latency / t, cost: cost / t,
                            health: health / t, quota: quota / t, priority: priority / t,
                            providerPreference: providerPreference / t,
                            localPreference: localPreference / t,
                            contextHeadroom: contextHeadroom / t)
    }
}

/// Which latency statistic `lowest_latency` (and the latency score dimension) uses.
public enum LatencyMetric: String, Codable, Sendable, CaseIterable {
    case timeToFirstToken = "ttft"
    case p50
    case p95
    case totalDuration = "total"
    public var displayName: String {
        switch self {
        case .timeToFirstToken: return "Time to first token"
        case .p50: return "p50 latency"
        case .p95: return "p95 latency"
        case .totalDuration: return "Total generation time"
        }
    }
}

/// A complete, serializable routing policy. One of these belongs to each
/// logical model — there is no global policy.
public struct RoutingPolicy: Codable, Sendable, Hashable {
    public var strategy: RoutingStrategyKind
    public var scoreWeights: ScoreWeights
    public var latencyMetric: LatencyMetric
    /// When true, targets whose circuit is open are skipped entirely.
    public var respectCircuitBreakers: Bool
    /// When true, targets over their rate limit / quota are skipped.
    public var respectQuotas: Bool
    /// Cap on how many targets a single request may attempt.
    public var maxCandidates: Int
    /// Deterministic tie-breaking makes the simulator reproducible.
    public var deterministic: Bool

    public init(strategy: RoutingStrategyKind = .priority,
                scoreWeights: ScoreWeights = .balanced,
                latencyMetric: LatencyMetric = .timeToFirstToken,
                respectCircuitBreakers: Bool = true,
                respectQuotas: Bool = true,
                maxCandidates: Int = 8,
                deterministic: Bool = false) {
        self.strategy = strategy
        self.scoreWeights = scoreWeights
        self.latencyMetric = latencyMetric
        self.respectCircuitBreakers = respectCircuitBreakers
        self.respectQuotas = respectQuotas
        self.maxCandidates = maxCandidates
        self.deterministic = deterministic
    }
}

public struct RetryConfig: Codable, Sendable, Hashable {
    /// Retries against the *same* target, per attempt.
    public var maxRetriesPerTarget: Int
    public var initialBackoffSeconds: Double
    public var backoffMultiplier: Double
    public var maxBackoffSeconds: Double
    public var jitter: Bool
    /// Honour `Retry-After` when the provider sends one.
    public var respectRetryAfter: Bool

    public init(maxRetriesPerTarget: Int = 1, initialBackoffSeconds: Double = 0.25,
                backoffMultiplier: Double = 2.0, maxBackoffSeconds: Double = 8,
                jitter: Bool = true, respectRetryAfter: Bool = true) {
        self.maxRetriesPerTarget = maxRetriesPerTarget
        self.initialBackoffSeconds = initialBackoffSeconds
        self.backoffMultiplier = backoffMultiplier
        self.maxBackoffSeconds = maxBackoffSeconds
        self.jitter = jitter
        self.respectRetryAfter = respectRetryAfter
    }
    public static let `default` = RetryConfig()

    public func backoff(forRetry n: Int) -> Double {
        let base = min(maxBackoffSeconds, initialBackoffSeconds * pow(backoffMultiplier, Double(max(0, n))))
        guard jitter else { return base }
        return base * Double.random(in: 0.5...1.0)
    }
}

public struct FailoverConfig: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Total provider attempts (retries included) allowed for one request.
    public var maxAttempts: Int
    /// Per-`FailureKind` overrides; unset kinds use `FailureKind.defaultDisposition`.
    public var dispositions: [FailureKind: FailureDisposition]

    public init(enabled: Bool = true, maxAttempts: Int = 4,
                dispositions: [FailureKind: FailureDisposition] = [:]) {
        self.enabled = enabled; self.maxAttempts = maxAttempts; self.dispositions = dispositions
    }
    public static let `default` = FailoverConfig()

    public func disposition(for kind: FailureKind) -> FailureDisposition {
        let base = dispositions[kind] ?? kind.defaultDisposition
        if !enabled && base.allowsFailover { return .returnToClient }
        return base
    }

    // FailureKind is a String enum, but dictionary keys with non-String raw types
    // encode as arrays; encode explicitly as an object for a readable config file.
    private enum CodingKeys: String, CodingKey { case enabled, maxAttempts, dispositions }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 4
        let raw = try c.decodeIfPresent([String: String].self, forKey: .dispositions) ?? [:]
        var out: [FailureKind: FailureDisposition] = [:]
        for (k, v) in raw {
            if let kk = FailureKind(rawValue: k), let vv = FailureDisposition(rawValue: v) { out[kk] = vv }
        }
        dispositions = out
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(maxAttempts, forKey: .maxAttempts)
        var raw: [String: String] = [:]
        for (k, v) in dispositions { raw[k.rawValue] = v.rawValue }
        try c.encode(raw, forKey: .dispositions)
    }
}

public struct TimeoutConfig: Codable, Sendable, Hashable {
    /// Hard deadline for the whole request, across every attempt.
    public var overallSeconds: Double
    /// Per-attempt ceiling; the executor also caps this by remaining budget.
    public var perAttemptSeconds: Double
    /// How long to wait for the first token before treating a stream as stalled.
    public var firstTokenSeconds: Double

    public init(overallSeconds: Double = 120, perAttemptSeconds: Double = 60, firstTokenSeconds: Double = 45) {
        self.overallSeconds = overallSeconds
        self.perAttemptSeconds = perAttemptSeconds
        self.firstTokenSeconds = firstTokenSeconds
    }
    public static let `default` = TimeoutConfig()
}

/// Speculative parallel execution. Off by default because it multiplies cost.
public struct HedgeConfig: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Start a second target if the first has produced nothing after this long.
    public var delaySeconds: Double
    /// Maximum simultaneous in-flight attempts.
    public var maxParallel: Int
    /// Never hedge onto a target whose blended price exceeds this (nil = no cap).
    public var maxCostPerMTok: Double?

    public init(enabled: Bool = false, delaySeconds: Double = 0.8, maxParallel: Int = 2, maxCostPerMTok: Double? = nil) {
        self.enabled = enabled; self.delaySeconds = delaySeconds
        self.maxParallel = maxParallel; self.maxCostPerMTok = maxCostPerMTok
    }
    public static let disabled = HedgeConfig()
}

public struct BudgetRules: Codable, Sendable, Hashable {
    /// Reject requests whose estimated cost exceeds this.
    public var maxCostPerRequestUSD: Double?
    public var dailyCostCapUSD: Double?
    public var monthlyCostCapUSD: Double?
    /// When a cap is hit, prefer free/flat-rate targets rather than failing.
    public var degradeToFreeTargets: Bool

    public init(maxCostPerRequestUSD: Double? = nil, dailyCostCapUSD: Double? = nil,
                monthlyCostCapUSD: Double? = nil, degradeToFreeTargets: Bool = true) {
        self.maxCostPerRequestUSD = maxCostPerRequestUSD
        self.dailyCostCapUSD = dailyCostCapUSD
        self.monthlyCostCapUSD = monthlyCostCapUSD
        self.degradeToFreeTargets = degradeToFreeTargets
    }
    public static let unlimited = BudgetRules()
    public var isUnlimited: Bool {
        maxCostPerRequestUSD == nil && dailyCostCapUSD == nil && monthlyCostCapUSD == nil
    }
}

/// Request parameter defaults applied when the client does not specify them.
public struct RequestDefaults: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var systemPrompt: String?
    /// Prepend rather than replace a client-supplied system message.
    public var systemPromptMode: SystemPromptMode
    public var reasoningEffort: ReasoningEffort?

    public init(temperature: Double? = nil, topP: Double? = nil, maxOutputTokens: Int? = nil,
                systemPrompt: String? = nil, systemPromptMode: SystemPromptMode = .prepend,
                reasoningEffort: ReasoningEffort? = nil) {
        self.temperature = temperature; self.topP = topP
        self.maxOutputTokens = maxOutputTokens; self.systemPrompt = systemPrompt
        self.systemPromptMode = systemPromptMode; self.reasoningEffort = reasoningEffort
    }
    public static let none = RequestDefaults()

    public enum SystemPromptMode: String, Codable, Sendable, CaseIterable {
        case prepend, replace, onlyIfAbsent = "only_if_absent"
        public var displayName: String {
            switch self {
            case .prepend: return "Prepend to client's system prompt"
            case .replace: return "Replace client's system prompt"
            case .onlyIfAbsent: return "Use only when client sends none"
            }
        }
    }
}

/// A candidate target inside a logical model: a (provider account, model) pair
/// plus the routing knobs that only make sense in this logical model's context.
public struct TargetRef: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var providerID: UUID
    public var modelUUID: UUID
    public var enabled: Bool
    /// Weight for `weighted_random`; also a tie-break elsewhere.
    public var weight: Double
    /// Overrides `PhysicalModel.qualityScore` for this logical model only.
    public var qualityOverride: Double?
    /// Multiplies the modelled cost when scoring (e.g. to disfavour a target).
    public var costMultiplier: Double
    /// Extra per-target attempt timeout, overriding the logical model's.
    public var timeoutOverrideSeconds: Double?

    public init(id: UUID = UUID(), providerID: UUID, modelUUID: UUID, enabled: Bool = true,
                weight: Double = 1, qualityOverride: Double? = nil,
                costMultiplier: Double = 1, timeoutOverrideSeconds: Double? = nil) {
        self.id = id; self.providerID = providerID; self.modelUUID = modelUUID
        self.enabled = enabled; self.weight = weight
        self.qualityOverride = qualityOverride; self.costMultiplier = costMultiplier
        self.timeoutOverrideSeconds = timeoutOverrideSeconds
    }
}

/// The user-facing abstraction: a named group clients ask for by `model`.
public struct LogicalModel: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The wire name, e.g. "coding". Must be unique.
    public var name: String
    public var summary: String
    public var enabled: Bool
    /// Ordered candidates; order *is* priority for order-sensitive strategies.
    public var targets: [TargetRef]
    public var policy: RoutingPolicy
    public var retry: RetryConfig
    public var failover: FailoverConfig
    public var timeouts: TimeoutConfig
    public var hedging: HedgeConfig
    public var budget: BudgetRules
    public var defaults: RequestDefaults
    /// Capabilities every target must have, on top of what the request implies.
    public var requiredCapabilities: CapabilityFlags
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, summary: String = "", enabled: Bool = true,
                targets: [TargetRef] = [], policy: RoutingPolicy = RoutingPolicy(),
                retry: RetryConfig = .default, failover: FailoverConfig = .default,
                timeouts: TimeoutConfig = .default, hedging: HedgeConfig = .disabled,
                budget: BudgetRules = .unlimited, defaults: RequestDefaults = .none,
                requiredCapabilities: CapabilityFlags = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.summary = summary; self.enabled = enabled
        self.targets = targets; self.policy = policy; self.retry = retry
        self.failover = failover; self.timeouts = timeouts; self.hedging = hedging
        self.budget = budget; self.defaults = defaults
        self.requiredCapabilities = requiredCapabilities
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}
