import Foundation

/// What the router needs to know about a request. Both chat and embedding
/// requests reduce to this, which keeps the router free of API concepts.
public struct RoutingRequest: Sendable {
    public var logicalModelName: String
    public var requirements: CapabilityRequirements
    public var promptTokens: Int
    public var maxOutputTokens: Int?
    public var isStreaming: Bool

    public init(logicalModelName: String, requirements: CapabilityRequirements,
                promptTokens: Int, maxOutputTokens: Int? = nil, isStreaming: Bool = false) {
        self.logicalModelName = logicalModelName
        self.requirements = requirements
        self.promptTokens = promptTokens
        self.maxOutputTokens = maxOutputTokens
        self.isStreaming = isStreaming
    }

    public init(_ request: CanonicalRequest) {
        self.init(logicalModelName: request.requestedModel,
                  requirements: request.capabilityRequirements,
                  promptTokens: request.estimatedPromptTokens,
                  maxOutputTokens: request.maxOutputTokens,
                  isStreaming: request.stream)
    }

    public init(_ request: CanonicalEmbeddingRequest) {
        self.init(logicalModelName: request.requestedModel,
                  requirements: request.capabilityRequirements,
                  promptTokens: request.estimatedPromptTokens)
    }
}

/// Turns a request plus a snapshot into a `RoutePlan` and a full explanation of
/// how it got there. Pure and synchronous — no I/O, no actor hops — which is
/// what makes the simulator and the routing tests possible.
public struct Router: Sendable {
    public var scorer: TargetScorer

    public init(scorer: TargetScorer = TargetScorer()) {
        self.scorer = scorer
    }

    public func route(_ request: RoutingRequest,
                      snapshot: RoutingSnapshot,
                      roundRobinCursor: Int = 0,
                      randomSeed: UInt64? = nil) throws -> RoutingDecision {

        guard let resolved = snapshot.logicalModel(named: request.logicalModelName) else {
            let known = snapshot.logicalModelNames
            throw DerbyError(kind: .modelUnavailable,
                             message: "Unknown model '\(request.logicalModelName)'."
                                + (known.isEmpty
                                   ? " No logical models are configured yet."
                                   : " Available Derby models: \(known.joined(separator: ", "))."),
                             providerStatus: 404)
        }
        let lm = resolved.definition
        var exclusions: [ExclusionRecord] = []

        // 1. Availability (turned off in config).
        var eligible: [ResolvedTarget] = []
        for t in resolved.targets {
            if let reason = t.unavailableReason {
                exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                                  modelID: t.modelID, stage: .disabled, reason: reason))
            } else {
                eligible.append(t)
            }
        }

        if resolved.targets.isEmpty {
            throw DerbyError(kind: .modelUnavailable,
                             message: "Logical model '\(lm.name)' has no targets. Add at least one provider model to it in Logical Models.",
                             providerStatus: 503)
        }

        // 2. Capability filter — request-derived plus logical-model-mandated.
        var requirements = request.requirements
        requirements.required.formUnion(lm.requiredCapabilities)
        eligible = eligible.filter { t in
            if let reason = requirements.unmetReason(for: t.capabilities) {
                exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                                  modelID: t.modelID, stage: .capability, reason: reason))
                return false
            }
            return true
        }

        // 3. Health filter.
        if lm.policy.respectCircuitBreakers {
            eligible = eligible.filter { t in
                let h = snapshot.health(for: t.key)
                if h.state == .disabled {
                    exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                                      modelID: t.modelID, stage: .health,
                                                      reason: "target manually disabled"))
                    return false
                }
                if h.circuit == .open {
                    var reason = "circuit open"
                    if let k = h.lastFailureKind { reason += " after \(k.displayName.lowercased()) failures" }
                    if let at = h.circuitReopensAt {
                        let secs = max(0, at.timeIntervalSinceNow)
                        reason += String(format: ", retrying in %.0fs", secs)
                    }
                    exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                                      modelID: t.modelID, stage: .health, reason: reason))
                    return false
                }
                return true
            }
        }

        // 4. Quota / rate-limit filter.
        if lm.policy.respectQuotas {
            eligible = eligible.filter { t in
                if let rl = snapshot.health(for: t.key).rateLimit, rl.isExhausted {
                    exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                                      modelID: t.modelID, stage: .quota,
                                                      reason: "provider rate limit reached (\(rl.summary))"))
                    return false
                }
                return true
            }
        }

        // 5. Budget filter.
        if let cap = lm.budget.maxCostPerRequestUSD {
            let estimatedOutput = request.maxOutputTokens ?? 1024
            var affordable: [ResolvedTarget] = []
            for t in eligible {
                let usage = CanonicalUsage(inputTokens: request.promptTokens, outputTokens: estimatedOutput)
                let estimate = (t.pricing?.cost(for: usage)).map { $0 * max(0.01, t.ref.costMultiplier) }
                // Unknown pricing never blocks routing.
                if let e = estimate, e > cap {
                    exclusions.append(ExclusionRecord(
                        targetLabel: t.label, providerName: t.providerName, modelID: t.modelID,
                        stage: .budget,
                        reason: "estimated \(e.usdString) exceeds the \(cap.usdString) per-request cap"))
                } else {
                    affordable.append(t)
                }
            }
            // Degrade rather than fail when only free targets remain affordable.
            if affordable.isEmpty && lm.budget.degradeToFreeTargets {
                affordable = eligible.filter { $0.pricing?.isFlatRate == true }
                if !affordable.isEmpty {
                    exclusions.removeAll { x in affordable.contains { $0.label == x.targetLabel } }
                }
            }
            eligible = affordable
        }

        guard !eligible.isEmpty else {
            let reason = exclusions.first?.reason ?? "no targets configured"
            throw DerbyError(kind: exclusions.contains(where: { $0.stage == .capability }) ? .capabilityMismatch : .modelUnavailable,
                             message: "No eligible target for '\(lm.name)'. \(exclusions.count) candidate\(exclusions.count == 1 ? " was" : "s were") filtered out; first reason: \(reason).",
                             providerStatus: 503,
                             detail: exclusions.map { "\($0.targetLabel): \($0.reason)" }.joined(separator: "; "))
        }

        // 6. Rank with this logical model's own strategy.
        let strategy = StrategyRegistry.strategy(for: lm.policy.strategy)
        let context = RoutingContext(policy: lm.policy,
                                     health: snapshot.health,
                                     promptTokens: request.promptTokens,
                                     scorer: scorer,
                                     roundRobinCursor: roundRobinCursor,
                                     randomSeed: lm.policy.deterministic ? (randomSeed ?? 1) : randomSeed)
        var ranked = strategy.rank(eligible, context: context)

        // 7. Apply the candidate cap.
        let limit = max(1, min(lm.policy.maxCandidates,
                               lm.failover.enabled ? lm.failover.maxAttempts : 1))
        if ranked.count > limit {
            for dropped in ranked[limit...] {
                exclusions.append(ExclusionRecord(targetLabel: dropped.target.label,
                                                  providerName: dropped.target.providerName,
                                                  modelID: dropped.target.modelID,
                                                  stage: .cap,
                                                  reason: "ranked #\(ranked.firstIndex(where: { $0.target.id == dropped.target.id })! + 1), beyond the \(limit)-attempt limit"))
            }
            ranked = Array(ranked[..<limit])
        }

        // 8. Build the plan.
        let attempts = ranked.enumerated().map { i, r in
            PlannedAttempt(target: r.target,
                           timeout: r.target.ref.timeoutOverrideSeconds
                               ?? min(lm.timeouts.perAttemptSeconds, r.target.account.requestTimeoutSeconds),
                           maxRetries: lm.retry.maxRetriesPerTarget,
                           score: r.score,
                           rank: i)
        }
        // A strict chain never runs targets in parallel.
        var hedging = lm.hedging
        if lm.policy.strategy == .failoverChain { hedging.enabled = false }

        let plan = RoutePlan(logicalModelName: lm.name,
                             attempts: attempts,
                             overallDeadlineSeconds: lm.timeouts.overallSeconds,
                             firstTokenTimeoutSeconds: lm.timeouts.firstTokenSeconds,
                             retry: lm.retry,
                             failover: lm.failover,
                             hedging: hedging,
                             defaults: lm.defaults,
                             budget: lm.budget)

        let evaluations = ranked.enumerated().map { i, r in
            CandidateEvaluation(targetLabel: r.target.label,
                                providerName: r.target.providerName,
                                modelID: r.target.modelID,
                                rank: i,
                                score: r.score,
                                components: r.components,
                                note: r.note)
        }

        return RoutingDecision(logicalModelName: lm.name,
                               strategy: lm.policy.strategy,
                               plan: plan,
                               evaluations: evaluations,
                               exclusions: exclusions,
                               explanation: strategy.explain(ranked, context: context),
                               snapshotVersion: snapshot.version)
    }

    /// Re-ranks the remaining attempts after a context-overflow failure so the
    /// executor prefers a target with a strictly larger window.
    public static func preferringLargerContext(than target: ResolvedTarget,
                                               attempts: [PlannedAttempt]) -> [PlannedAttempt] {
        let current = target.capabilities.contextWindow ?? 0
        let larger = attempts.filter { ($0.target.capabilities.contextWindow ?? 0) > current }
        let rest = attempts.filter { ($0.target.capabilities.contextWindow ?? 0) <= current }
        return larger + rest
    }
}
