import Foundation

/// One planned provider attempt. The executor may retry within an attempt, and
/// moves to the next attempt on failover.
public struct PlannedAttempt: Sendable {
    public var target: ResolvedTarget
    /// Ceiling for this attempt; the executor further caps it by the remaining
    /// overall budget.
    public var timeout: Double
    public var maxRetries: Int
    public var score: Double
    public var rank: Int
}

/// The router's output: an ordered set of attempts plus the budgets that govern
/// them. Everything the executor needs, and nothing about *how* to talk to a
/// provider.
public struct RoutePlan: Sendable {
    public var logicalModelName: String
    public var attempts: [PlannedAttempt]
    public var overallDeadlineSeconds: Double
    public var firstTokenTimeoutSeconds: Double
    public var retry: RetryConfig
    public var failover: FailoverConfig
    public var hedging: HedgeConfig
    public var defaults: RequestDefaults
    public var budget: BudgetRules
    /// What to do when a conversation does not fit the chosen target.
    public var compaction: CompactionPolicy
    /// The model that writes the summary, already resolved. Nil means the target
    /// answering the request does it itself.
    public var compactor: ResolvedTarget?

    public var isEmpty: Bool { attempts.isEmpty }

    public init(logicalModelName: String, attempts: [PlannedAttempt],
                overallDeadlineSeconds: Double, firstTokenTimeoutSeconds: Double,
                retry: RetryConfig, failover: FailoverConfig, hedging: HedgeConfig,
                defaults: RequestDefaults, budget: BudgetRules,
                compaction: CompactionPolicy = .disabled,
                compactor: ResolvedTarget? = nil) {
        self.logicalModelName = logicalModelName
        self.attempts = attempts
        self.overallDeadlineSeconds = overallDeadlineSeconds
        self.firstTokenTimeoutSeconds = firstTokenTimeoutSeconds
        self.retry = retry
        self.failover = failover
        self.hedging = hedging
        self.defaults = defaults
        self.budget = budget
        self.compaction = compaction
        self.compactor = compactor
    }
}

/// Why a target was dropped, and at which stage. Recorded verbatim in request
/// history so every decision can be explained after the fact.
public struct ExclusionRecord: Sendable, Hashable, Codable {
    public enum Stage: String, Sendable, Codable {
        case disabled, capability, health, quota, budget, cap
        /// Separate from `capability` because the remedy is different: a model
        /// that cannot see images will never serve this request, while one whose
        /// window is too small becomes usable the moment the conversation is
        /// shortened or compaction is enabled.
        case contextWindow = "context_window"
        public var displayName: String {
            switch self {
            case .disabled: return "Disabled"
            case .capability: return "Capability"
            case .health: return "Health"
            case .quota: return "Quota"
            case .budget: return "Budget"
            case .cap: return "Candidate cap"
            case .contextWindow: return "Context window"
            }
        }
    }
    public var targetLabel: String
    public var providerName: String
    public var modelID: String
    public var stage: Stage
    public var reason: String

    public init(targetLabel: String, providerName: String, modelID: String, stage: Stage, reason: String) {
        self.targetLabel = targetLabel; self.providerName = providerName
        self.modelID = modelID; self.stage = stage; self.reason = reason
    }
}

/// A scored, ranked candidate with the per-dimension breakdown that produced it.
public struct CandidateEvaluation: Sendable, Hashable, Codable {
    public var targetLabel: String
    public var providerName: String
    public var modelID: String
    public var rank: Int
    public var score: Double
    /// Dimension name → weighted contribution. Empty for strategies that do not
    /// score (priority, round robin).
    public var components: [String: Double]
    public var note: String?

    public init(targetLabel: String, providerName: String, modelID: String, rank: Int,
                score: Double, components: [String: Double] = [:], note: String? = nil) {
        self.targetLabel = targetLabel; self.providerName = providerName; self.modelID = modelID
        self.rank = rank; self.score = score; self.components = components; self.note = note
    }
}

/// Everything about one routing decision, for the inspector and the simulator.
public struct RoutingDecision: Sendable {
    public var logicalModelName: String
    public var strategy: RoutingStrategyKind
    public var plan: RoutePlan
    public var evaluations: [CandidateEvaluation]
    public var exclusions: [ExclusionRecord]
    public var explanation: String
    public var snapshotVersion: UInt64

    public var selected: CandidateEvaluation? { evaluations.first }

    /// A compact, human-readable trace of the whole decision.
    public var trace: String {
        var lines: [String] = []
        lines.append("Requested logical model: \(logicalModelName)")
        lines.append("Strategy: \(strategy.displayName)")
        lines.append("")
        lines.append("Candidates:")
        if evaluations.isEmpty { lines.append("  (none eligible)") }
        for e in evaluations {
            let scoreText = e.components.isEmpty ? "" : String(format: "  score %.3f", e.score)
            lines.append("  \(e.rank + 1). ✓ \(e.targetLabel)\(scoreText)")
        }
        for x in exclusions {
            lines.append("     ✗ \(x.targetLabel) — \(x.reason)")
        }
        lines.append("")
        if let s = plan.attempts.first {
            lines.append("Selected: \(s.target.label)")
        } else {
            lines.append("Selected: none")
        }
        lines.append("Reason: \(explanation)")
        return lines.joined(separator: "\n")
    }
}
