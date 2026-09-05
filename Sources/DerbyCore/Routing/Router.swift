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
    /// Room kept free for the answer when a client specifies no `max_tokens`.
    /// Small enough not to exclude modest local models, large enough that a
    /// chosen target can actually reply.
    public static let defaultOutputReserveTokens = 1024

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

        // 2. Capability filter, from what the request itself needs.
        //
        // There is deliberately no user-set "required capabilities" here. Demanding
        // a capability no target has could only ever empty the group — an error the
        // user would be creating for themselves. What a group offers is decided by
        // its targets, narrowed by the contract below.
        var requirements = request.requirements

        // The group's declared contract is enforced, not just advertised. If it
        // has been narrowed to text, a vision request is refused here rather
        // than being quietly routed to a target that happens to support it —
        // otherwise `/v1/models` would be telling clients something untrue.
        let constraints = lm.constraints ?? LogicalModelConstraints()
        if let allowed = constraints.allowedCapabilities {
            let withheld = requirements.required.subtracting(allowed)
            if !withheld.isEmpty {
                throw DerbyError(
                    kind: .capabilityMismatch,
                    message: "'\(lm.name)' is configured to offer only \(allowed.names.joined(separator: ", ")); this request needs \(withheld.label). Enable it for this logical model, or use one that offers it.",
                    providerStatus: 400)
            }
        }
        if let cap = constraints.maxContextTokens, request.promptTokens > cap {
            throw DerbyError(
                kind: .contextOverflow,
                message: "'\(lm.name)' is capped at \(cap.formattedTokens) of prompt; this request is about \(request.promptTokens.formattedTokens). Raise the cap for this logical model, or send less context.",
                providerStatus: 400)
        }

        // A prompt that merely *fits* is not enough: the model still needs room
        // to answer. When the client sends no `max_tokens` the request itself
        // reserves nothing, which would let a 30k conversation land on a 32k
        // model with no space for a reply. Reserve the logical model's default
        // answer size, or a modest floor.
        if request.maxOutputTokens == nil {
            let reserve = constraints.maxOutputTokens
                ?? lm.defaults.maxOutputTokens
                ?? Router.defaultOutputReserveTokens
            requirements.minContextTokens = (requirements.minContextTokens ?? 0) + reserve
        }
        //
        // Capability *flags* always bind: a model without vision cannot be given
        // an image. The context limit is different — when compaction is enabled
        // the conversation can be shortened to fit, so a target that is merely
        // too small stays eligible and is marked instead of dropped.
        let compaction = lm.compaction ?? .disabled
        var needsCompaction: Set<UUID> = []

        var flagsOnly = requirements
        flagsOnly.minContextTokens = nil
        flagsOnly.minOutputTokens = nil

        eligible = eligible.filter { t in
            if let reason = flagsOnly.unmetReason(for: t.capabilities) {
                exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                                  modelID: t.modelID, stage: .capability, reason: reason))
                return false
            }
            guard let reason = requirements.unmetReason(for: t.capabilities) else { return true }
            if compaction.enabled {
                needsCompaction.insert(t.id)
                return true
            }
            exclusions.append(ExclusionRecord(targetLabel: t.label, providerName: t.providerName,
                                              modelID: t.modelID, stage: .contextWindow, reason: reason))
            return false
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
            // Distinguish "too long" from "cannot do this". A client that hears
            // CONTEXT_OVERFLOW knows to shorten the conversation; hearing
            // CAPABILITY_MISMATCH it would go looking for a different model.
            let onlyContext = !exclusions.isEmpty
                && exclusions.allSatisfy { $0.stage == .contextWindow }
            let kind: FailureKind
            if onlyContext {
                kind = .contextOverflow
            } else if exclusions.contains(where: { $0.stage == .capability }) {
                kind = .capabilityMismatch
            } else {
                kind = .modelUnavailable
            }
            var message = "No eligible target for '\(lm.name)'. \(exclusions.count) candidate\(exclusions.count == 1 ? " was" : "s were") filtered out; first reason: \(reason)."
            if onlyContext && !compaction.enabled {
                message += " Enable compaction on this model to let a shorter version of the conversation run on a smaller target."
            }
            throw DerbyError(kind: kind,
                             message: message,
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

        // Resolve the compactor here, where the snapshot is available, so the
        // executor only has to run what it is given.
        var compactor: ResolvedTarget?
        if compaction.enabled, compaction.strategy == .summarize, let choice = compaction.compactor {
            compactor = snapshot.logicalModels.values
                .flatMap(\.targets)
                .first { $0.account.id == choice.providerID && $0.model.id == choice.modelUUID }
        }

        let plan = RoutePlan(logicalModelName: lm.name,
                             attempts: attempts,
                             overallDeadlineSeconds: lm.timeouts.overallSeconds,
                             firstTokenTimeoutSeconds: lm.timeouts.firstTokenSeconds,
                             retry: lm.retry,
                             failover: lm.failover,
                             hedging: hedging,
                             defaults: lm.defaults,
                             budget: lm.budget,
                             compaction: compaction,
                             compactor: compactor)

        let evaluations = ranked.enumerated().map { i, r in
            var note = r.note
            if needsCompaction.contains(r.target.id) {
                let shortened = "conversation will be shortened to fit \((r.target.capabilities.effectiveInputLimit ?? 0).formattedTokens)"
                note = note.map { "\($0) · \(shortened)" } ?? shortened
            }
            return CandidateEvaluation(targetLabel: r.target.label,
                                       providerName: r.target.providerName,
                                       modelID: r.target.modelID,
                                       rank: i,
                                       score: r.score,
                                       components: r.components,
                                       note: note)
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
