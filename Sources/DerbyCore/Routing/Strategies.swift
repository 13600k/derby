import Foundation

/// Inputs a strategy may consider. Deliberately free of provider concepts.
public struct RoutingContext: Sendable {
    public var policy: RoutingPolicy
    public var health: [TargetKey: TargetHealth]
    public var promptTokens: Int
    public var scorer: TargetScorer
    /// Rotating cursor supplied by the router for round-robin fairness.
    public var roundRobinCursor: Int
    /// When set, random choices become reproducible (used by the simulator).
    public var randomSeed: UInt64?
    /// Share of each target's account capacity already committed, by target id.
    public var loadUtilization: [UUID: Double]
    /// Whether each target's model is already loaded, by target id.
    public var warmth: [UUID: ModelWarmth]
    /// What each target's server last said it was working on, by target id.
    public var occupancy: [UUID: ServerOccupancy]
    /// Lineage of the model that wrote the conversation's latest answer.
    public var conversationLineage: ModelLineage?

    public init(policy: RoutingPolicy, health: [TargetKey: TargetHealth], promptTokens: Int,
                scorer: TargetScorer = TargetScorer(), roundRobinCursor: Int = 0,
                randomSeed: UInt64? = nil, loadUtilization: [UUID: Double] = [:],
                warmth: [UUID: ModelWarmth] = [:], occupancy: [UUID: ServerOccupancy] = [:],
                conversationLineage: ModelLineage? = nil) {
        self.policy = policy; self.health = health; self.promptTokens = promptTokens
        self.scorer = scorer; self.roundRobinCursor = roundRobinCursor; self.randomSeed = randomSeed
        self.loadUtilization = loadUtilization; self.warmth = warmth; self.occupancy = occupancy
        self.conversationLineage = conversationLineage
    }

    public func health(for t: ResolvedTarget) -> TargetHealth {
        health[t.key] ?? TargetHealth(key: t.key)
    }
    public func load(for t: ResolvedTarget) -> Double { loadUtilization[t.id] ?? 0 }
    public func warmth(for t: ResolvedTarget) -> ModelWarmth { warmth[t.id] ?? .unknown }
    public func occupancy(for t: ResolvedTarget) -> ServerOccupancy? { occupancy[t.id] }
    public func continuity(for t: ResolvedTarget) -> LineageAffinity? {
        conversationLineage.map { $0.affinity(with: t.lineage) }
    }
}

public struct RankedTarget: Sendable {
    public var target: ResolvedTarget
    public var score: Double
    public var components: [String: Double]
    public var note: String?
    public init(target: ResolvedTarget, score: Double, components: [String: Double] = [:], note: String? = nil) {
        self.target = target; self.score = score; self.components = components; self.note = note
    }
}

/// A selection algorithm. Implementations are pure: same inputs, same output
/// (except where a seed is absent and randomness is intended).
public protocol RoutingStrategy: Sendable {
    var kind: RoutingStrategyKind { get }
    /// Orders eligible targets best-first.
    func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget]
    /// One-line justification for the winner, shown in request history.
    func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String
}

extension RoutingStrategy {
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) ranked first under \(kind.displayName.lowercased()) routing."
    }
}

/// Deterministic PRNG so simulations reproduce exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Priority

public struct PriorityStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .priority
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        let denom = Double(max(1, targets.count - 1))
        return targets.sorted { $0.order < $1.order }.map {
            RankedTarget(target: $0, score: 1 - Double($0.order) / denom)
        }
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) is the highest-priority eligible target."
    }
}

/// Strict chain: identical ordering to priority, but the executor is told never
/// to hedge, so each target is only ever tried after the ones above it fail.
public struct FailoverChainStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .failoverChain
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        PriorityStrategy().rank(targets, context: context)
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) is first in the failover chain."
    }
}

// MARK: - Weighted random

public struct WeightedRandomStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .weightedRandom
    public init() {}

    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        var pool = targets
        var out: [RankedTarget] = []
        var generator: any RandomNumberGenerator = context.randomSeed.map { SeededGenerator(seed: $0) } ?? SystemRandomNumberGenerator()
        let totalWeight = targets.reduce(0.0) { $0 + max(0, $1.ref.weight) }

        // Sample without replacement so the tail becomes the failover order.
        while !pool.isEmpty {
            let weights = pool.map { max(0.0001, $0.ref.weight) }
            let sum = weights.reduce(0, +)
            let roll = Double.random(in: 0..<sum, using: &generator)
            var acc = 0.0
            var picked = pool.count - 1
            for (i, w) in weights.enumerated() {
                acc += w
                if roll < acc { picked = i; break }
            }
            let t = pool.remove(at: picked)
            let share = totalWeight > 0 ? max(0, t.ref.weight) / totalWeight : 0
            out.append(RankedTarget(target: t, score: share,
                                    note: String(format: "%.0f%% share", share * 100)))
        }
        return out
    }

    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) was drawn from the weighted pool (\(top.note ?? "")); remaining targets form the failover order."
    }
}

// MARK: - Weighted score

public struct WeightedScoreStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .weightedScore
    public init() {}

    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        let weights = context.policy.scoreWeights
        var out: [RankedTarget] = targets.map { t in
            let d = context.scorer.dimensions(for: t, health: context.health(for: t),
                                              metric: context.policy.latencyMetric,
                                              candidateCount: targets.count,
                                              promptTokens: context.promptTokens,
                                              loadUtilization: context.load(for: t),
                                              warmth: context.warmth(for: t),
                                              continuity: context.continuity(for: t))
            let (total, components) = d.weighted(by: weights)
            return RankedTarget(target: t, score: total, components: components)
        }
        out.sort { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            return a.target.order < b.target.order   // stable, priority-order tie-break
        }
        return out
    }

    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        let best = top.components.max { $0.value < $1.value }
        var s = String(format: "%@ scored highest (%.3f)", top.target.label, top.score)
        if let best { s += " — led by \(Self.label(for: best.key))." } else { s += "." }
        if ranked.count > 1 {
            s += String(format: " Next best %@ at %.3f.", ranked[1].target.label, ranked[1].score)
        }
        return s
    }

    /// Human label for a score dimension, shared with the UI.
    public static func label(for key: String) -> String {
        switch key {
        case "quality": return "quality"
        case "latency": return "measured latency"
        case "cost": return "cost"
        case "health": return "health"
        case "quota": return "spare quota"
        case "priority": return "configured priority"
        case "providerPreference": return "provider preference"
        case "localPreference": return "local preference"
        case "contextHeadroom": return "context headroom"
        case "load": return "spare capacity"
        case "warmth": return "a model already in memory"
        case "continuity": return "conversation continuity"
        default: return key
        }
    }
}

// MARK: - Latency / cost

public struct LowestLatencyStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .lowestLatency
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        let metric = context.policy.latencyMetric
        let scorer = context.scorer
        return targets.map { t -> RankedTarget in
            let h = context.health(for: t)
            let measured = h.latency(for: metric)
            let score = measured.map { scorer.latencyReference / (scorer.latencyReference + $0) } ?? scorer.unknownPrior
            let note = measured.map { "\(metric.displayName) \($0.msString)" } ?? "no samples yet"
            return RankedTarget(target: t, score: score, components: ["latency": score], note: note)
        }.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            return a.target.order < b.target.order
        }
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) has the best \(context.policy.latencyMetric.displayName.lowercased()) (\(top.note ?? "no data"))."
    }
}

public struct LowestCostStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .lowestCost
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        targets.map { t -> RankedTarget in
            let price = t.pricing
            let effective: Double?
            if price?.isFlatRate == true { effective = 0 }
            else { effective = price?.blendedPerMTok.map { $0 * max(0.01, t.ref.costMultiplier) } }
            let ref = context.scorer.costReference
            let score = effective.map { ref / (ref + $0) } ?? context.scorer.unknownPrior
            let note: String
            if let e = effective {
                note = e == 0 ? "no marginal cost" : String(format: "≈$%.2f/Mtok blended", e)
            } else {
                note = "price unknown"
            }
            return RankedTarget(target: t, score: score, components: ["cost": score], note: note)
        }.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            return a.target.order < b.target.order
        }
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) is the cheapest eligible target (\(top.note ?? ""))."
    }
}

// MARK: - Round robin

public struct RoundRobinStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .roundRobin
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        guard !targets.isEmpty else { return [] }
        let ordered = targets.sorted { $0.order < $1.order }
        let offset = ((context.roundRobinCursor % ordered.count) + ordered.count) % ordered.count
        let rotated = Array(ordered[offset...] + ordered[..<offset])
        return rotated.enumerated().map { i, t in
            RankedTarget(target: t, score: 1 - Double(i) / Double(max(1, rotated.count)),
                         note: i == 0 ? "next in rotation" : nil)
        }
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) is next in the rotation."
    }
}

// MARK: - Locality preference

public struct LocalFirstStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .localFirst
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        let inner = WeightedScoreStrategy().rank(targets, context: context)
        return inner
            .sorted { a, b in
                if a.target.isLocal != b.target.isLocal { return a.target.isLocal }
                if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
                return a.target.order < b.target.order
            }
            .map { RankedTarget(target: $0.target, score: $0.score, components: $0.components,
                                note: $0.target.isLocal ? "local" : "cloud fallback") }
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return top.target.isLocal
            ? "\(top.target.label) is a healthy local target, which local-first routing prefers."
            : "No local target was eligible, so \(top.target.label) was used as the cloud fallback."
    }
}

public struct CloudFirstStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .cloudFirst
    public init() {}
    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        let inner = WeightedScoreStrategy().rank(targets, context: context)
        return inner
            .sorted { a, b in
                if a.target.isLocal != b.target.isLocal { return !a.target.isLocal }
                if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
                return a.target.order < b.target.order
            }
            .map { RankedTarget(target: $0.target, score: $0.score, components: $0.components,
                                note: $0.target.isLocal ? "local emergency fallback" : "cloud") }
    }
    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return top.target.isLocal
            ? "Every cloud target was unavailable, so \(top.target.label) was used as the local fallback."
            : "\(top.target.label) is the best-scoring cloud target."
    }
}

// MARK: - Load

/// Ranks by spare capacity on each target's account right now, counting
/// requests already reserved for it as well as those running.
///
/// Capacity is the account's own concurrency limit, so a local server allowed
/// two requests and a hosted API allowed forty are compared by how full they
/// are, not by raw counts. Ties go to a model that is already loaded, then to
/// the configured order.
public struct LeastLoadedStrategy: RoutingStrategy {
    public let kind: RoutingStrategyKind = .leastLoaded
    public init() {}

    public func rank(_ targets: [ResolvedTarget], context: RoutingContext) -> [RankedTarget] {
        targets.map { t -> RankedTarget in
            let utilization = context.load(for: t)
            let score = max(0, 1 - min(1, utilization))
            // The server's own account of itself beats Derby's arithmetic.
            let note: String
            if let reported = context.occupancy(for: t) {
                note = reported.summary
            } else {
                let committed = Int((utilization * Double(t.concurrencyCapacity)).rounded())
                note = "\(committed) of \(t.concurrencyCapacity) slots in use"
            }
            return RankedTarget(target: t, score: score, components: ["load": score], note: note)
        }.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            let warmA = context.warmth(for: a.target).score, warmB = context.warmth(for: b.target).score
            if warmA != warmB { return warmA > warmB }
            return a.target.order < b.target.order
        }
    }

    public func explain(_ ranked: [RankedTarget], context: RoutingContext) -> String {
        guard let top = ranked.first else { return "No eligible targets remained after filtering." }
        return "\(top.target.label) has the most spare capacity (\(top.note ?? "idle"))."
    }
}

// MARK: - Registry

public enum StrategyRegistry {
    /// The one place strategies are instantiated. Adding a strategy is a case
    /// here plus a type above — the executor and adapters are untouched.
    public static func strategy(for kind: RoutingStrategyKind) -> any RoutingStrategy {
        switch kind {
        case .priority: return PriorityStrategy()
        case .weightedRandom: return WeightedRandomStrategy()
        case .weightedScore: return WeightedScoreStrategy()
        case .lowestLatency: return LowestLatencyStrategy()
        case .lowestCost: return LowestCostStrategy()
        case .roundRobin: return RoundRobinStrategy()
        case .failoverChain: return FailoverChainStrategy()
        case .localFirst: return LocalFirstStrategy()
        case .cloudFirst: return CloudFirstStrategy()
        case .leastLoaded: return LeastLoadedStrategy()
        }
    }
}
