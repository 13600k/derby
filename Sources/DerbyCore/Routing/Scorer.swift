import Foundation

/// Normalizes each routing dimension to 0...1 where 1 is "most preferred".
/// Every dimension has a defined value when data is missing, so incomplete
/// pricing or a brand-new target never removes it from consideration.
public struct TargetScorer: Sendable {
    /// Latency at which the latency score is 0.5 (seconds).
    public var latencyReference: Double = 2.0
    /// Blended $/Mtok at which the cost score is 0.5.
    public var costReference: Double = 3.0
    /// Score used when a dimension has no data — deliberately optimistic so
    /// untried targets get sampled instead of starving.
    public var unknownPrior: Double = 0.6

    public init() {}

    public struct Dimensions: Sendable {
        public var quality = 0.0
        public var latency = 0.0
        public var cost = 0.0
        public var health = 0.0
        public var quota = 0.0
        public var priority = 0.0
        public var providerPreference = 0.0
        public var localPreference = 0.0
        public var contextHeadroom = 0.0

        public func weighted(by w: ScoreWeights) -> (total: Double, components: [String: Double]) {
            let n = w.normalized
            let parts: [(String, Double)] = [
                ("quality", quality * n.quality),
                ("latency", latency * n.latency),
                ("cost", cost * n.cost),
                ("health", health * n.health),
                ("quota", quota * n.quota),
                ("priority", priority * n.priority),
                ("providerPreference", providerPreference * n.providerPreference),
                ("localPreference", localPreference * n.localPreference),
                ("contextHeadroom", contextHeadroom * n.contextHeadroom),
            ]
            var components: [String: Double] = [:]
            var total = 0.0
            for (k, v) in parts where v != 0 {
                components[k] = v
                total += v
            }
            return (total, components)
        }
    }

    public func dimensions(for target: ResolvedTarget,
                           health: TargetHealth,
                           metric: LatencyMetric,
                           candidateCount: Int,
                           promptTokens: Int) -> Dimensions {
        var d = Dimensions()
        d.quality = min(1, max(0, target.quality / 100))

        if let l = health.latency(for: metric), l > 0 {
            d.latency = latencyReference / (latencyReference + l)
        } else {
            d.latency = unknownPrior
        }

        if let p = target.pricing {
            if p.isFlatRate {
                d.cost = 1.0
            } else if let blended = p.blendedPerMTok {
                let effective = blended * max(0.01, target.ref.costMultiplier)
                d.cost = costReference / (costReference + effective)
            } else {
                d.cost = unknownPrior
            }
        } else {
            d.cost = unknownPrior
        }

        d.health = health.state.scoreValue * (health.totalSamples == 0 ? 1 : (0.5 + 0.5 * health.successRate))
        d.quota = 1 - (health.rateLimit?.pressure ?? 0)

        let denom = max(1, candidateCount - 1)
        d.priority = 1 - Double(min(target.order, denom)) / Double(denom)

        d.providerPreference = min(1, max(0, target.account.preferenceScore / 100))
        d.localPreference = target.isLocal ? 1 : 0

        if let window = target.capabilities.contextWindow, window > 0, promptTokens > 0 {
            // Full marks once the window is 4x the prompt; scales down from there.
            d.contextHeadroom = min(1, Double(window) / Double(promptTokens * 4))
        } else {
            d.contextHeadroom = unknownPrior
        }
        return d
    }
}
