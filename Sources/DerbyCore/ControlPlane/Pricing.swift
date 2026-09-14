import Foundation

/// Per-million-token prices in USD. Nil components mean "unknown", which never
/// blocks routing — cost simply stops contributing to the score.
public struct Pricing: Codable, Sendable, Hashable {
    public var inputPerMTok: Double?
    public var outputPerMTok: Double?
    public var cachedInputPerMTok: Double?
    public var cacheWritePerMTok: Double?
    /// Marks targets the user already pays a flat fee for (subscriptions, local
    /// hardware). Marginal cost is zero, which cost-aware routing should prefer.
    public var isFlatRate: Bool

    public init(inputPerMTok: Double? = nil, outputPerMTok: Double? = nil,
                cachedInputPerMTok: Double? = nil, cacheWritePerMTok: Double? = nil,
                isFlatRate: Bool = false) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cachedInputPerMTok = cachedInputPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.isFlatRate = isFlatRate
    }

    public static let free = Pricing(inputPerMTok: 0, outputPerMTok: 0, isFlatRate: true)
    public var isKnown: Bool { isFlatRate || inputPerMTok != nil || outputPerMTok != nil }

    public func cost(for usage: CanonicalUsage) -> Double? {
        if isFlatRate { return 0 }
        guard inputPerMTok != nil || outputPerMTok != nil else { return nil }
        let m = 1_000_000.0
        let cachedRate = cachedInputPerMTok ?? (inputPerMTok.map { $0 * 0.1 })
        let freshInput = max(0, usage.inputTokens - usage.cachedInputTokens - usage.cacheWriteTokens)
        var total = 0.0
        total += Double(freshInput) * (inputPerMTok ?? 0) / m
        total += Double(usage.cachedInputTokens) * (cachedRate ?? 0) / m
        total += Double(usage.cacheWriteTokens) * (cacheWritePerMTok ?? inputPerMTok ?? 0) / m
        total += Double(usage.outputTokens) * (outputPerMTok ?? 0) / m
        return total
    }

    /// Blended per-million-token price used to rank targets before a request runs.
    /// Assumes a 3:1 input:output mix, which is typical for chat workloads.
    public var blendedPerMTok: Double? {
        if isFlatRate { return 0 }
        guard let i = inputPerMTok ?? outputPerMTok, let o = outputPerMTok ?? inputPerMTok else { return nil }
        return i * 0.75 + o * 0.25
    }

    public func merged(with override: Pricing?) -> Pricing {
        guard let o = override else { return self }
        return Pricing(inputPerMTok: o.inputPerMTok ?? inputPerMTok,
                       outputPerMTok: o.outputPerMTok ?? outputPerMTok,
                       cachedInputPerMTok: o.cachedInputPerMTok ?? cachedInputPerMTok,
                       cacheWritePerMTok: o.cacheWritePerMTok ?? cacheWritePerMTok,
                       isFlatRate: o.isFlatRate || isFlatRate)
    }
}

extension Double {
    public var usdString: String {
        if self == 0 { return "$0.00" }
        if abs(self) < 0.01 { return String(format: "$%.4f", self) }
        if abs(self) < 1 { return String(format: "$%.3f", self) }
        return String(format: "$%.2f", self)
    }
}
