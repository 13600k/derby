import Foundation

/// What a logical model can promise a client, derived from the targets in it.
///
/// The distinction matters. A client such as an agent framework decides *how to
/// use* a model from this: whether it may send images, define tools, or rely on
/// a context size. Advertising the union of the group's targets would be unsafe —
/// a capability only one target has is not something the group guarantees.
///
/// So Derby reports both:
/// * `guaranteed` — supported by **every** eligible target, so a request using it
///   keeps full redundancy.
/// * `available` — supported by **at least one** target. Such a request still
///   works, because capability filtering routes it to the targets that qualify,
///   but with fewer of them to fail over to.
public struct LogicalModelCapabilitySummary: Sendable, Hashable {
    public var guaranteed: CapabilityFlags
    public var available: CapabilityFlags
    /// Smallest context window among targets: what the group can always accept.
    public var guaranteedContextWindow: Int?
    /// Largest context window reachable, via the targets that have it.
    public var maxContextWindow: Int?
    public var guaranteedMaxOutputTokens: Int?
    public var maxOutputTokens: Int?
    public var embeddingDimensions: Int?
    public var targetCount: Int
    /// Targets that cannot serve this group's request shape at all.
    public var incompatible: [Incompatibility]
    /// What the targets could do before the group's own constraints narrowed it.
    /// Non-nil only when a constraint actually removed something.
    public var unconstrained: CapabilityFlags?
    /// Capabilities the targets support but the group deliberately withholds.
    public var withheld: CapabilityFlags {
        guard let unconstrained else { return [] }
        return unconstrained.subtracting(available)
    }

    public struct Incompatibility: Sendable, Hashable {
        public var targetLabel: String
        public var reason: String
    }

    public var inputModalities: [String] { available.inputModalities }
    public var outputModalities: [String] { available.outputModalities }

    /// Capabilities present on some but not all targets — usable, but with
    /// reduced failover.
    public var partial: CapabilityFlags { available.subtracting(guaranteed) }

    public static let empty = LogicalModelCapabilitySummary(
        guaranteed: [], available: [], targetCount: 0, incompatible: [])

    /// True when the group offers less than its targets could.
    public var isNarrowed: Bool { !withheld.isEmpty }

    public init(guaranteed: CapabilityFlags, available: CapabilityFlags,
                guaranteedContextWindow: Int? = nil, maxContextWindow: Int? = nil,
                guaranteedMaxOutputTokens: Int? = nil, maxOutputTokens: Int? = nil,
                embeddingDimensions: Int? = nil,
                targetCount: Int, incompatible: [Incompatibility],
                unconstrained: CapabilityFlags? = nil) {
        self.guaranteed = guaranteed
        self.available = available
        self.guaranteedContextWindow = guaranteedContextWindow
        self.maxContextWindow = maxContextWindow
        self.guaranteedMaxOutputTokens = guaranteedMaxOutputTokens
        self.maxOutputTokens = maxOutputTokens
        self.embeddingDimensions = embeddingDimensions
        self.targetCount = targetCount
        self.incompatible = incompatible
        self.unconstrained = unconstrained
    }

    /// Derives the summary for a resolved logical model.
    public static func summarize(_ model: ResolvedLogicalModel) -> LogicalModelCapabilitySummary {
        let usable = model.targets.filter { $0.unavailableReason == nil }
        guard !usable.isEmpty else { return .empty }

        // A group serving chat cannot include a target that produces no text —
        // a text→image model, or an embeddings-only model. Those are reported as
        // incompatible rather than quietly skewing the group's advertised shape.
        let wantsEmbeddings = usable.allSatisfy { $0.capabilities.flags.contains(.embeddings) }
        var incompatible: [Incompatibility] = []
        var participating: [ResolvedTarget] = []

        for target in usable {
            let flags = target.capabilities.flags
            if wantsEmbeddings {
                if flags.contains(.embeddings) { participating.append(target) }
                else {
                    incompatible.append(.init(targetLabel: target.label,
                                              reason: "produces text, not embeddings"))
                }
                continue
            }
            if flags.canServeText {
                participating.append(target)
            } else if flags.contains(.embeddings) {
                incompatible.append(.init(targetLabel: target.label,
                                          reason: "an embedding model cannot answer a chat request"))
            } else {
                let outputs = flags.outputModalities.joined(separator: "/")
                incompatible.append(.init(
                    targetLabel: target.label,
                    reason: outputs.isEmpty
                        ? "produces no text output"
                        : "produces \(outputs), not text, so it cannot answer a chat request"))
            }
        }
        guard let first = participating.first else {
            return LogicalModelCapabilitySummary(guaranteed: [], available: [],
                                                 targetCount: 0, incompatible: incompatible)
        }

        var guaranteed = first.capabilities.flags
        var available: CapabilityFlags = []
        var guaranteedContext: Int?
        var maxContext: Int?
        var guaranteedOutput: Int?
        var maxOutput: Int?
        var dimensions: Int?
        var everyTargetStatesContext = true
        var everyTargetStatesOutput = true

        for target in participating {
            let caps = target.capabilities
            guaranteed.formIntersection(caps.flags)
            available.formUnion(caps.flags)

            if let window = caps.effectiveInputLimit {
                guaranteedContext = guaranteedContext.map { Swift.min($0, window) } ?? window
                maxContext = maxContext.map { Swift.max($0, window) } ?? window
            } else {
                // One unknown window means the group cannot promise a floor.
                everyTargetStatesContext = false
            }
            if let out = caps.maxOutputTokens {
                guaranteedOutput = guaranteedOutput.map { Swift.min($0, out) } ?? out
                maxOutput = maxOutput.map { Swift.max($0, out) } ?? out
            } else {
                everyTargetStatesOutput = false
            }
            if dimensions == nil { dimensions = caps.embeddingDimensions }
        }

        // The group's declared contract narrows what the targets can do. It can
        // only ever subtract: unchecking vision hides a capability the targets
        // have, but checking one they lack would be a promise Derby cannot keep.
        let constraints = model.definition.constraints ?? LogicalModelConstraints()
        let rawAvailable = available

        return LogicalModelCapabilitySummary(
            guaranteed: constraints.narrowing(guaranteed),
            available: constraints.narrowing(available),
            guaranteedContextWindow: constraints.capping(
                context: everyTargetStatesContext ? guaranteedContext : nil),
            maxContextWindow: constraints.capping(context: maxContext),
            guaranteedMaxOutputTokens: constraints.capping(
                output: everyTargetStatesOutput ? guaranteedOutput : nil),
            maxOutputTokens: constraints.capping(output: maxOutput),
            embeddingDimensions: dimensions,
            targetCount: participating.count,
            incompatible: incompatible,
            unconstrained: constraints.isEmpty ? nil : rawAvailable)
    }
}
