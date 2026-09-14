import Foundation

/// Runs a `RoutePlan`. Owns retries, failover, deadlines, cancellation,
/// concurrency permits and hedging — and knows nothing about any provider's
/// wire format, which it delegates entirely to adapters.
public final class Executor: Sendable {
    private let registry: AdapterRegistry
    private let transport: any HTTPTransport
    private let secrets: any SecretStore
    private let credentials: CredentialCache
    private let health: HealthRegistry
    private let telemetry: any TelemetrySink
    /// Who wrote each answer, so the next turn can be carried faithfully.
    public let ledger: HandoffLedger

    public init(registry: AdapterRegistry = .default,
                transport: any HTTPTransport = URLSessionTransport.shared,
                secrets: any SecretStore,
                credentials: CredentialCache,
                health: HealthRegistry,
                telemetry: any TelemetrySink = NullTelemetrySink(),
                ledger: HandoffLedger = HandoffLedger()) {
        self.registry = registry
        self.transport = transport
        self.secrets = secrets
        self.credentials = credentials
        self.health = health
        self.telemetry = telemetry
        self.ledger = ledger
    }

    // MARK: - Non-streaming

    public func execute(_ request: CanonicalRequest,
                        decision: RoutingDecision,
                        meta: RequestMeta) async throws -> ExecutionOutcome {
        do {
            let outcome = try await executePlan(request, decision: decision, meta: meta)
            await releaseReservation(meta)
            return outcome
        } catch {
            await releaseReservation(meta)
            throw error
        }
    }

    private func executePlan(_ original: CanonicalRequest,
                             decision: RoutingDecision,
                             meta: RequestMeta) async throws -> ExecutionOutcome {
        let normalized = ConversationNormalizer.normalize(original)
        let request = normalized.request
        let plan = decision.plan
        let startedAt = Date()
        let t0 = Clock.monotonic
        let deadline = t0 + plan.overallDeadlineSeconds

        var records: [AttemptRecord] = []
        var queue = plan.attempts
        var attemptIndex = 0
        var retryTotal = 0
        var failoverTotal = 0
        var lastError = DerbyError(kind: .modelUnavailable,
                                   message: "No provider attempt was made for '\(plan.logicalModelName)'.")

        while !queue.isEmpty {
            if attemptIndex >= plan.failover.maxAttempts {
                lastError = DerbyError(kind: lastError.kind,
                                       message: lastError.message + " (attempt limit of \(plan.failover.maxAttempts) reached)")
                break
            }
            let remaining = deadline - Clock.monotonic
            if remaining <= 0.05 {
                lastError = DerbyError.timeout("Request budget of \(plan.overallDeadlineSeconds.msString) was exhausted after \(records.count) attempt(s).")
                break
            }

            let planned = queue.removeFirst()
            let applied = applyDefaults(request, plan: plan)

            // Hedging: race this attempt against the next one after a delay.
            let hedgeCandidate = hedgeTarget(plan: plan, queue: queue, remaining: remaining)
            let results: [AttemptResult]
            if let hedge = hedgeCandidate {
                queue.removeAll { $0.target.id == hedge.target.id }
                results = await runHedged(primary: planned, hedge: hedge,
                                          primaryIndex: attemptIndex, request: applied,
                                          plan: plan, deadline: deadline, meta: meta,
                                          repairs: normalized.repairs)
            } else {
                results = [await runAttemptWithRetries(planned, index: attemptIndex, request: applied,
                                                       plan: plan, deadline: deadline, meta: meta,
                                                       repairs: normalized.repairs)]
            }

            for r in results {
                records.append(r.record)
                retryTotal += r.record.retryCount
            }
            attemptIndex += results.count

            if let win = results.first(where: { $0.isSuccess }), let response = win.response {
                await ledger.record(request: request, response: response.message,
                                    origin: MessageOrigin(target: win.target))
                let record = makeRecord(meta: meta, decision: decision, attempts: records,
                                        startedAt: startedAt, totalSeconds: Clock.monotonic - t0,
                                        ttft: win.record.timeToFirstTokenSeconds,
                                        finalTarget: win.target,
                                        response: response, error: nil,
                                        retryCount: retryTotal, failoverCount: failoverTotal)
                await telemetry.record(record)
                return ExecutionOutcome(response: response, record: record, target: win.target)
            }

            // Everything failed; decide what to do based on the worst failure.
            guard let failure = results.compactMap({ $0.error }).first else { break }
            lastError = failure
            let disposition = plan.failover.disposition(for: failure.kind)
            if disposition == .abort || disposition == .returnToClient || !disposition.allowsFailover {
                break
            }
            if disposition == .failoverToLargerContext {
                queue = Router.preferringLargerContext(than: planned.target, attempts: queue)
            }
            if !queue.isEmpty { failoverTotal += 1 }
        }

        let record = makeRecord(meta: meta, decision: decision, attempts: records,
                                startedAt: startedAt, totalSeconds: Clock.monotonic - t0,
                                ttft: nil, finalTarget: nil, response: nil, error: lastError,
                                retryCount: retryTotal, failoverCount: failoverTotal)
        await telemetry.record(record)
        throw lastError
    }

    // MARK: - Embeddings

    public func embed(_ request: CanonicalEmbeddingRequest,
                      decision: RoutingDecision,
                      meta: RequestMeta) async throws -> EmbeddingOutcome {
        do {
            let outcome = try await embedPlan(request, decision: decision, meta: meta)
            await releaseReservation(meta)
            return outcome
        } catch {
            await releaseReservation(meta)
            throw error
        }
    }

    private func embedPlan(_ request: CanonicalEmbeddingRequest,
                           decision: RoutingDecision,
                           meta: RequestMeta) async throws -> EmbeddingOutcome {
        let plan = decision.plan
        let startedAt = Date()
        let t0 = Clock.monotonic
        let deadline = t0 + plan.overallDeadlineSeconds
        var records: [AttemptRecord] = []
        var lastError = DerbyError(kind: .modelUnavailable, message: "No embedding target was attempted.")

        for (index, planned) in plan.attempts.enumerated() {
            let remaining = deadline - Clock.monotonic
            if remaining <= 0.05 { lastError = .timeout("Request budget exhausted."); break }

            let target = planned.target
            let key = target.key
            let admission = await health.admit(key, accountID: target.account.id,
                                               limits: target.account.rateLimits,
                                               respectCircuit: true, respectQuota: true)
            if admission != .allowed {
                records.append(skipRecord(target: target, index: index, reason: describe(admission), score: planned.score))
                continue
            }
            await health.acquire(key, accountID: target.account.id, converting: meta.loadReservation)
            defer { Task { await self.health.release(key, accountID: target.account.id) } }

            let adapter = registry.adapter(for: target.account.kind)
            let ctx = ProviderContext(account: target.account, transport: transport, secrets: secrets,
                                      credentials: credentials, attemptTimeout: min(planned.timeout, remaining),
                                      modelCapabilities: target.capabilities)
            let attemptStart = Clock.monotonic
            do {
                let response = try await withDeadline(min(planned.timeout, remaining),
                                                      message: "\(target.label) exceeded \(planned.timeout.msString)") {
                    try await adapter.embed(request, model: target.modelID, ctx: ctx)
                }
                let duration = Clock.monotonic - attemptStart
                let cost = target.pricing?.cost(for: response.usage) ?? 0
                await health.record(AttemptOutcome(key: key, success: true, totalSeconds: duration,
                                                   usage: response.usage, costUSD: cost))
                records.append(AttemptRecord(id: IDGenerator.attemptID(index + 1), index: index,
                                             providerID: target.account.id, providerName: target.providerName,
                                             providerKind: target.account.kind.rawValue, modelID: target.modelID,
                                             targetLabel: target.label, status: .success, startedAt: Date(),
                                             durationSeconds: duration, usage: response.usage, costUSD: cost,
                                             routingScore: planned.score))
                let record = makeRecord(meta: meta, decision: decision, attempts: records, startedAt: startedAt,
                                        totalSeconds: Clock.monotonic - t0, ttft: nil, finalTarget: target,
                                        response: nil, error: nil, retryCount: 0, failoverCount: index,
                                        usageOverride: response.usage, costOverride: cost)
                await telemetry.record(record)
                return EmbeddingOutcome(response: response, record: record, target: target)
            } catch {
                let derby = normalize(error)
                let duration = Clock.monotonic - attemptStart
                await health.record(AttemptOutcome(key: key, success: false, failure: derby.kind,
                                                   totalSeconds: duration, httpStatus: derby.providerStatus))
                records.append(failureRecord(target: target, index: index, error: derby,
                                             duration: duration, retries: 0, score: planned.score))
                lastError = derby
                if !plan.failover.disposition(for: derby.kind).allowsFailover { break }
            }
        }
        let record = makeRecord(meta: meta, decision: decision, attempts: records, startedAt: startedAt,
                                totalSeconds: Clock.monotonic - t0, ttft: nil, finalTarget: nil,
                                response: nil, error: lastError, retryCount: 0, failoverCount: max(0, records.count - 1))
        await telemetry.record(record)
        throw lastError
    }

    // MARK: - Context compaction

    /// Adapts `request` to one target's context window.
    ///
    /// Returns it untouched whenever it already fits, which is the ordinary
    /// case — the work only happens on a target too small for the conversation,
    /// and only when the logical model opted in. Throwing here fails this
    /// attempt like any other, so the plan simply moves to the next target.
    private func prepareRequest(_ request: CanonicalRequest, for target: ResolvedTarget,
                                plan: RoutePlan, deadline: Double,
                                meta: RequestMeta) async throws -> (CanonicalRequest, CompactionRecord?) {
        guard plan.compaction.enabled else { return (request, nil) }
        let reserve = request.maxOutputTokens ?? Router.defaultOutputReserveTokens
        guard let limit = target.capabilities.effectiveInputLimit, limit > 0,
              ContextCompactor.needsCompaction(request, inputLimit: limit, outputReserve: reserve) else {
            return (request, nil)
        }

        var summarizerName: String?
        var summarize: ContextCompactor.Summarizer?
        if plan.compaction.strategy == .summarize, let compactor = plan.compactor {
            summarizerName = compactor.label
            // Never let summarizing eat the whole request budget: it is
            // preparation, not the answer.
            let budget = min(plan.compaction.timeoutSeconds, max(deadline - Clock.monotonic - 1, 1))
            summarize = { dropped in
                try await self.summarize(dropped, using: compactor, timeout: budget)
            }
        }

        let outcome = try await ContextCompactor.compact(request, inputLimit: limit, outputReserve: reserve,
                                                        policy: plan.compaction, targetLabel: target.label,
                                                        summarizerName: summarizerName, summarize: summarize)
        await telemetry.log(LogEntry(level: .info, category: "compaction",
                                     message: outcome.record.summary, requestID: meta.requestID))
        return (outcome.request, outcome.record)
    }

    private func summarize(_ dropped: [CanonicalMessage], using compactor: ResolvedTarget,
                           timeout: Double) async throws -> String {
        let adapter = registry.adapter(for: compactor.account.kind)
        let ctx = ProviderContext(account: compactor.account, transport: transport, secrets: secrets,
                                  credentials: credentials, attemptTimeout: timeout,
                                  modelCapabilities: compactor.capabilities)
        // Leave room for the instructions and the summary itself.
        let transcriptBudget = compactor.capabilities.effectiveInputLimit.map { max($0 - 2_000, 1_000) }
        let req = ContextCompactor.summarizationRequest(for: dropped, model: compactor.modelID,
                                                        transcriptTokenBudget: transcriptBudget)
        let response = try await withDeadline(timeout,
                                              message: "The compaction model \(compactor.label) did not respond within \(timeout.msString).") {
            try await adapter.execute(req, model: compactor.modelID, ctx: ctx)
        }
        return response.message.joinedText
    }

    // MARK: - Attempt execution

    struct AttemptResult: Sendable {
        var target: ResolvedTarget
        var record: AttemptRecord
        var response: CanonicalResponse?
        var error: DerbyError?

        var isSuccess: Bool { response != nil }
        static func success(_ target: ResolvedTarget, _ response: CanonicalResponse, _ record: AttemptRecord) -> AttemptResult {
            AttemptResult(target: target, record: record, response: response, error: nil)
        }
        static func failure(_ target: ResolvedTarget, _ error: DerbyError, _ record: AttemptRecord) -> AttemptResult {
            AttemptResult(target: target, record: record, response: nil, error: error)
        }
    }

    private func runAttemptWithRetries(_ planned: PlannedAttempt, index: Int,
                                       request original: CanonicalRequest, plan: RoutePlan,
                                       deadline: Double, meta: RequestMeta,
                                       repairs: [String] = []) async -> AttemptResult {
        let target = planned.target
        let key = target.key
        let circuit = await health.health(for: key).circuit

        let admission = await health.admit(key, accountID: target.account.id,
                                           limits: target.account.rateLimits,
                                           respectCircuit: true, respectQuota: true)
        guard admission == .allowed else {
            let reason = describe(admission)
            await telemetry.log(LogEntry(level: .debug, category: "executor",
                                         message: "Skipped \(target.label): \(reason)", requestID: meta.requestID))
            return .failure(target, DerbyError(kind: admissionFailureKind(admission), message: reason),
                            skipRecord(target: target, index: index, reason: reason, score: planned.score))
        }

        await health.acquire(key, accountID: target.account.id, converting: meta.loadReservation)
        defer { Task { await self.health.release(key, accountID: target.account.id) } }

        let adapter = registry.adapter(for: target.account.kind)
        var retries = 0
        var lastError = DerbyError(kind: .unknown, message: "unknown")
        let attemptStartedAt = Date()
        let attemptT0 = Clock.monotonic

        // Carry the conversation to this particular model: what an earlier
        // model left behind reaches it only if it can read it, and the
        // structure follows its rules.
        var handoff = HandoffPlanner.plan(original, for: HandoffTarget(target: target),
                                          policy: plan.handoff, repairs: repairs)
        /// Set once the target has refused the reasoning replayed to it, so the
        /// repair below is attempted exactly once.
        var withheldRejectedReasoning = false

        // Each target has its own window, so this is per attempt rather than
        // per request: a conversation that overflows the local model may fit
        // the cloud one the plan falls back to.
        var request: CanonicalRequest
        var compaction: CompactionRecord?
        do {
            (request, compaction) = try await prepareRequest(handoff.request, for: target, plan: plan,
                                                             deadline: deadline, meta: meta)
        } catch {
            let derby = normalize(error)
            var rec = failureRecord(target: target, index: index, error: derby,
                                    duration: Clock.monotonic - attemptT0, retries: 0,
                                    score: planned.score, circuit: circuit, startedAt: attemptStartedAt)
            rec.compaction = nil
            rec.handoff = handoff.record
            return .failure(target, derby, rec)
        }

        while true {
            let remaining = deadline - Clock.monotonic
            if remaining <= 0.05 {
                lastError = .timeout("No time left in the request budget for \(target.label).")
                break
            }
            let timeout = min(planned.timeout, remaining)
            let ctx = ProviderContext(account: target.account, transport: transport, secrets: secrets,
                                      credentials: credentials, attemptTimeout: timeout,
                                          modelCapabilities: target.capabilities)
            let callStart = Clock.monotonic
            do {
                var response = try await withDeadline(timeout,
                                                      message: "\(target.label) did not respond within \(timeout.msString)") {
                    try await adapter.execute(request, model: target.modelID, ctx: ctx)
                }
                response.message = Executor.finalize(response.message, target: target)
                let duration = Clock.monotonic - callStart
                let cost = target.pricing?.cost(for: response.usage) ?? 0
                await health.record(AttemptOutcome(key: key, success: true, totalSeconds: duration,
                                                   timeToFirstTokenSeconds: nil, httpStatus: 200,
                                                   usage: response.usage, costUSD: cost))
                let rec = AttemptRecord(id: IDGenerator.attemptID(index + 1), index: index,
                                        providerID: target.account.id, providerName: target.providerName,
                                        providerKind: target.account.kind.rawValue, modelID: target.modelID,
                                        targetLabel: target.label, status: .success,
                                        startedAt: attemptStartedAt,
                                        durationSeconds: Clock.monotonic - attemptT0,
                                        httpStatus: 200, retryCount: retries,
                                        usage: response.usage, costUSD: cost,
                                        circuitState: circuit, routingScore: planned.score,
                                        compaction: compaction, handoff: handoff.record)
                return .success(target, response, rec)
            } catch {
                let derby = normalize(error)
                lastError = derby
                let duration = Clock.monotonic - callStart
                await health.record(AttemptOutcome(key: key, success: false, failure: derby.kind,
                                                   totalSeconds: duration, httpStatus: derby.providerStatus))
                await health.recordFailureMessage(key, message: derby.message)

                if derby.kind == .clientCancelled { break }

                // Reasoning the target will not verify costs the thinking, not
                // the turn: the same target is asked again with the replay
                // withheld, and the record says that is what happened.
                if derby.kind == .reasoningRejected, !withheldRejectedReasoning {
                    withheldRejectedReasoning = true
                    var policy = plan.handoff
                    policy.replayReasoning = false
                    handoff = HandoffPlanner.plan(original, for: HandoffTarget(target: target),
                                                  policy: policy, repairs: repairs)
                    handoff.record.adjustments.append(
                        "re-sent without the replayed reasoning, which \(target.label) would not verify")
                    do {
                        (request, compaction) = try await prepareRequest(handoff.request, for: target, plan: plan,
                                                                        deadline: deadline, meta: meta)
                    } catch { break }
                    await telemetry.log(LogEntry(level: .debug, category: "executor",
                                                 message: "\(target.label) refused the replayed reasoning; re-sending without it",
                                                 requestID: meta.requestID))
                    continue
                }

                let disposition = plan.failover.disposition(for: derby.kind)
                guard disposition.allowsRetry, retries < planned.maxRetries else { break }

                var wait = plan.retry.backoff(forRetry: retries)
                if plan.retry.respectRetryAfter, let ra = derby.retryAfter { wait = max(wait, min(ra, 10)) }
                if Clock.monotonic + wait >= deadline { break }
                retries += 1
                await telemetry.log(LogEntry(level: .debug, category: "executor",
                                             message: "Retrying \(target.label) after \(derby.kind.rawValue) in \(wait.msString)",
                                             requestID: meta.requestID))
                do { try await backoffSleep(wait) } catch { break }
            }
        }
        var failed = failureRecord(target: target, index: index, error: lastError,
                                   duration: Clock.monotonic - attemptT0,
                                   retries: retries, score: planned.score,
                                   circuit: circuit, startedAt: attemptStartedAt)
        failed.compaction = compaction
        failed.handoff = handoff.record
        return .failure(target, lastError, failed)
    }

    /// Runs two attempts with a delay between them; the first success wins and
    /// the loser is cancelled and recorded as `hedge_lost`.
    private func runHedged(primary: PlannedAttempt, hedge: PlannedAttempt,
                           primaryIndex: Int, request: CanonicalRequest, plan: RoutePlan,
                           deadline: Double, meta: RequestMeta,
                           repairs: [String]) async -> [AttemptResult] {
        await telemetry.log(LogEntry(level: .debug, category: "executor",
                                     message: "Hedging \(primary.target.label) with \(hedge.target.label) after \(plan.hedging.delaySeconds.msString)",
                                     requestID: meta.requestID))
        return await withTaskGroup(of: (Int, AttemptResult).self) { group in
            group.addTask {
                (0, await self.runAttemptWithRetries(primary, index: primaryIndex, request: request,
                                                     plan: plan, deadline: deadline, meta: meta,
                                                     repairs: repairs))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(plan.hedging.delaySeconds * 1_000_000_000))
                if Task.isCancelled {
                    return (1, .failure(hedge.target, DerbyError.cancelled("hedge not needed"),
                                        self.hedgeLostRecord(target: hedge.target, index: primaryIndex + 1,
                                                             score: hedge.score)))
                }
                return (1, await self.runAttemptWithRetries(hedge, index: primaryIndex + 1, request: request,
                                                            plan: plan, deadline: deadline, meta: meta,
                                                            repairs: repairs))
            }

            var collected: [(Int, AttemptResult)] = []
            var winner: (Int, AttemptResult)?
            for await item in group {
                if item.1.isSuccess && winner == nil {
                    winner = item
                    group.cancelAll()
                } else {
                    collected.append(item)
                }
            }
            var out: [AttemptResult] = []
            if let w = winner {
                out.append(w.1)
                for c in collected {
                    // The loser's own record is kept, relabelled so history shows
                    // it was a hedge that lost rather than a real failure.
                    let loser = c.0 == 0 ? primary : hedge
                    out.append(.failure(loser.target, DerbyError.cancelled("Hedge lost the race"),
                                        self.hedgeLostRecord(target: loser.target,
                                                             index: c.0 == 0 ? primaryIndex : primaryIndex + 1,
                                                             score: loser.score,
                                                             duration: c.1.record.durationSeconds)))
                }
            } else {
                out = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return out
        }
    }

    private func hedgeTarget(plan: RoutePlan, queue: [PlannedAttempt], remaining: Double) -> PlannedAttempt? {
        guard plan.hedging.enabled, plan.hedging.maxParallel >= 2,
              remaining > plan.hedging.delaySeconds * 1.5,
              let next = queue.first else { return nil }
        if let cap = plan.hedging.maxCostPerMTok,
           let price = next.target.pricing?.blendedPerMTok, price > cap {
            return nil
        }
        return next
    }

    // MARK: - Streaming

    public func stream(_ request: CanonicalRequest,
                       decision: RoutingDecision,
                       meta: RequestMeta) -> AsyncThrowingStream<ExecutionStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runStream(request, decision: decision, meta: meta, continuation: continuation)
                await self.releaseReservation(meta)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(_ request: CanonicalRequest, decision: RoutingDecision, meta: RequestMeta,
                           continuation: AsyncThrowingStream<ExecutionStreamEvent, Error>.Continuation) async {
        let plan = decision.plan
        let startedAt = Date()
        let t0 = Clock.monotonic
        let deadline = t0 + plan.overallDeadlineSeconds
        var records: [AttemptRecord] = []
        var queue = plan.attempts
        var attemptIndex = 0
        var failoverTotal = 0
        /// Targets that refused the reasoning replayed to them, which are asked
        /// once more with it withheld rather than being failed over.
        var withholdReasoning: Set<TargetKey> = []
        var lastError = DerbyError(kind: .modelUnavailable,
                                   message: "No provider attempt was made for '\(plan.logicalModelName)'.")
        let normalized = ConversationNormalizer.normalize(request)
        let applied = applyDefaults(normalized.request, plan: plan)

        while !queue.isEmpty {
            if attemptIndex >= plan.failover.maxAttempts { break }
            let remaining = deadline - Clock.monotonic
            if remaining <= 0.05 {
                lastError = .timeout("Request budget of \(plan.overallDeadlineSeconds.msString) was exhausted.")
                break
            }
            let planned = queue.removeFirst()
            let target = planned.target
            let key = target.key
            let circuit = await health.health(for: key).circuit

            let admission = await health.admit(key, accountID: target.account.id,
                                               limits: target.account.rateLimits,
                                               respectCircuit: true, respectQuota: true)
            guard admission == .allowed else {
                let reason = describe(admission)
                records.append(skipRecord(target: target, index: attemptIndex, reason: reason, score: planned.score))
                lastError = DerbyError(kind: admissionFailureKind(admission), message: reason)
                attemptIndex += 1
                failoverTotal += 1
                continue
            }
            await health.acquire(key, accountID: target.account.id, converting: meta.loadReservation)

            let adapter = registry.adapter(for: target.account.kind)
            let attemptT0 = Clock.monotonic
            let attemptStartedAt = Date()
            var accumulator = StreamAccumulator()
            var shaper = StreamShaper(target: target)
            var sawContent = false
            var ttft: Double?
            var failure: DerbyError?

            // Same per-target shaping as the non-streaming path. It happens
            // before the first byte is written, so a stream never has to be
            // rewound because of it.
            var handoffPolicy = plan.handoff
            if withholdReasoning.contains(key) { handoffPolicy.replayReasoning = false }
            var handoff = HandoffPlanner.plan(applied, for: HandoffTarget(target: target),
                                              policy: handoffPolicy, repairs: normalized.repairs)
            if withholdReasoning.contains(key) {
                handoff.record.adjustments.append(
                    "re-sent without the replayed reasoning, which \(target.label) would not verify")
            }
            let outbound: CanonicalRequest
            let compaction: CompactionRecord?
            do {
                (outbound, compaction) = try await prepareRequest(handoff.request, for: target, plan: plan,
                                                                  deadline: deadline, meta: meta)
            } catch {
                let derby = normalize(error)
                await health.release(key, accountID: target.account.id)
                var failed = failureRecord(target: target, index: attemptIndex, error: derby,
                                           duration: Clock.monotonic - attemptT0, retries: 0,
                                           score: planned.score, circuit: circuit,
                                           startedAt: attemptStartedAt)
                failed.handoff = handoff.record
                records.append(failed)
                lastError = derby
                attemptIndex += 1
                failoverTotal += 1
                continue
            }

            do {
                let timeout = min(planned.timeout, deadline - Clock.monotonic)
                let ctx = ProviderContext(account: target.account, transport: transport, secrets: secrets,
                                          credentials: credentials, attemptTimeout: timeout,
                                          modelCapabilities: target.capabilities)
                // Opening the stream (headers + auth) is bounded by the
                // first-token timeout; the body is bounded by the attempt timeout.
                let events = try await withDeadline(min(plan.firstTokenTimeoutSeconds, timeout),
                                                    message: "\(target.label) did not start streaming within \(plan.firstTokenTimeoutSeconds.msString)") {
                    try await adapter.stream(outbound, model: target.modelID, ctx: ctx)
                }
                continuation.yield(.attemptStarted(target: target, attemptIndex: attemptIndex))

                // Pump the adapter stream through a channel so the inactivity
                // timeout can never leave a half-advanced iterator behind.
                let channel = AsyncEventChannel<CanonicalStreamEvent>()
                let pump = Task {
                    do {
                        for try await e in events {
                            try Task.checkCancellation()
                            await channel.push(e)
                        }
                        await channel.finish()
                    } catch {
                        await channel.finish(throwing: error)
                    }
                }
                defer { pump.cancel() }

                while true {
                    let budget = deadline - Clock.monotonic
                    if budget <= 0 { throw DerbyError.timeout("Request budget exhausted mid-stream.") }
                    // Until the first token arrives the tighter first-token
                    // timeout applies, so a silent provider fails over quickly.
                    let waitFor = sawContent ? min(planned.timeout, budget) : min(plan.firstTokenTimeoutSeconds, budget)
                    let stalled = sawContent
                    let label = target.label
                    let firstTokenLimit = plan.firstTokenTimeoutSeconds
                    let next = try await channel.next(
                        timeout: waitFor,
                        timeoutMessage: stalled
                            ? "\(label) stalled mid-stream"
                            : "\(label) produced no output within \(firstTokenLimit.msString)")
                    // Shaped before anyone sees it: inline reasoning split out,
                    // tool calls given ids that are unique, artifacts stamped
                    // with who issued them.
                    let shaped = next.map { shaper.shape($0) } ?? shaper.finish()
                    for event in shaped {
                        accumulator.ingest(event)
                        if event.isContentBearing && !sawContent {
                            sawContent = true
                            ttft = Clock.monotonic - attemptT0
                        }
                        continuation.yield(.canonical(event))
                    }
                    if next == nil { break }
                }
            } catch {
                failure = normalize(error)
            }

            let duration = Clock.monotonic - attemptT0
            await health.release(key, accountID: target.account.id)

            if let f = failure {
                let usage = accumulator.usage
                await health.record(AttemptOutcome(key: key, success: false, failure: f.kind,
                                                   totalSeconds: duration, timeToFirstTokenSeconds: ttft,
                                                   httpStatus: f.providerStatus, usage: usage))
                await health.recordFailureMessage(key, message: f.message)
                var failedRecord = failureRecord(target: target, index: attemptIndex, error: f, duration: duration,
                                                 retries: 0, score: planned.score, circuit: circuit,
                                                 startedAt: attemptStartedAt, ttft: ttft, usage: usage)
                failedRecord.compaction = compaction
                failedRecord.handoff = handoff.record
                records.append(failedRecord)
                lastError = f
                attemptIndex += 1

                // Streaming failover is only transparent before the client has
                // seen content. After that, end the stream honestly.
                if sawContent {
                    let record = makeRecord(meta: meta, decision: decision, attempts: records, startedAt: startedAt,
                                            totalSeconds: Clock.monotonic - t0, ttft: ttft, finalTarget: target,
                                            response: accumulator.makeResponse(fallbackModel: target.modelID),
                                            error: f, retryCount: 0, failoverCount: failoverTotal,
                                            midStream: true)
                    await telemetry.record(record)
                    continuation.yield(.failed(f, record))
                    continuation.finish()
                    return
                }
                // Reasoning this target will not verify: ask it again with the
                // replay withheld before giving up on it. Nothing has been
                // written to the client yet, so this is invisible but recorded.
                if f.kind == .reasoningRejected, !withholdReasoning.contains(key) {
                    withholdReasoning.insert(key)
                    queue.insert(planned, at: 0)
                    await telemetry.log(LogEntry(level: .debug, category: "executor",
                                                 message: "\(target.label) refused the replayed reasoning; re-sending without it",
                                                 requestID: meta.requestID))
                    continue
                }

                let disposition = plan.failover.disposition(for: f.kind)
                if !disposition.allowsFailover { break }
                if disposition == .failoverToLargerContext {
                    queue = Router.preferringLargerContext(than: target, attempts: queue)
                }
                if !queue.isEmpty { failoverTotal += 1 }
                continue
            }

            // Success.
            var response = accumulator.makeResponse(fallbackModel: target.modelID)
            response.message = Executor.finalize(response.message, target: target)
            await ledger.record(request: normalized.request, response: response.message,
                                origin: MessageOrigin(target: target))
            if response.usage.isEmpty {
                // Some OpenAI-compatible servers never report usage on a stream.
                // Derive a rough count so token and cost views are not blank,
                // flagged so the UI can show it as approximate.
                response.usage = .estimated(promptTokens: outbound.estimatedPromptTokens,
                                            completionText: accumulator.text,
                                            reasoningText: accumulator.reasoning)
            }
            let cost = target.pricing?.cost(for: response.usage) ?? 0
            await health.record(AttemptOutcome(key: key, success: true, totalSeconds: duration,
                                               timeToFirstTokenSeconds: ttft, httpStatus: 200,
                                               usage: response.usage, costUSD: cost))
            records.append(AttemptRecord(id: IDGenerator.attemptID(attemptIndex + 1), index: attemptIndex,
                                         providerID: target.account.id, providerName: target.providerName,
                                         providerKind: target.account.kind.rawValue, modelID: target.modelID,
                                         targetLabel: target.label, status: .success, startedAt: attemptStartedAt,
                                         durationSeconds: duration, timeToFirstTokenSeconds: ttft,
                                         httpStatus: 200, usage: response.usage, costUSD: cost,
                                         circuitState: circuit, routingScore: planned.score,
                                         compaction: compaction, handoff: handoff.record))
            let record = makeRecord(meta: meta, decision: decision, attempts: records, startedAt: startedAt,
                                    totalSeconds: Clock.monotonic - t0, ttft: ttft, finalTarget: target,
                                    response: response, error: nil, retryCount: 0, failoverCount: failoverTotal)
            await telemetry.record(record)
            continuation.yield(.finished(record))
            continuation.finish()
            return
        }

        let record = makeRecord(meta: meta, decision: decision, attempts: records, startedAt: startedAt,
                                totalSeconds: Clock.monotonic - t0, ttft: nil, finalTarget: nil,
                                response: nil, error: lastError, retryCount: 0, failoverCount: failoverTotal)
        await telemetry.record(record)
        continuation.finish(throwing: lastError)
    }

    // MARK: - Helpers

    private func releaseReservation(_ meta: RequestMeta) async {
        if let reservation = meta.loadReservation { await health.release(reservation) }
    }

    /// Normalizes an answer before the client or the ledger sees it.
    ///
    /// - Reasoning a server left inline as `<think>` moves to `reasoning`, so the
    ///   answer reads the same whichever server produced it.
    /// - Tool calls the provider gave no id, or only a positional placeholder
    ///   (`call_0`), get one that is unique across the conversation: a second
    ///   `call_0` two turns later would collide on every provider that matches
    ///   results to calls by id.
    /// - Opaque reasoning is stamped with the model and account that issued it,
    ///   since only they can read it back.
    static func finalize(_ message: CanonicalMessage, target: ResolvedTarget) -> CanonicalMessage {
        var m = message
        let text = m.joinedText
        if !text.isEmpty {
            let prefilled = LineageTraits.for(target.lineage).thinkTagPrefilled && (m.reasoning?.isEmpty ?? true)
            let split = ReasoningMarkup.split(text, prefilled: prefilled)
            if let reasoning = split.reasoning {
                let media = m.content.filter { $0.textValue == nil }
                m.content = (split.content.isEmpty ? [] : [.text(split.content)]) + media
                m.reasoning = ConversationNormalizer.joinText(m.reasoning, reasoning)
            }
        }
        var renamed: [String: String] = [:]
        for i in m.toolCalls.indices where needsToolCallID(m.toolCalls[i].id) {
            let fresh = "call_" + IDGenerator.short()
            if renamed[m.toolCalls[i].id] == nil { renamed[m.toolCalls[i].id] = fresh }
            m.toolCalls[i].id = fresh
        }
        for i in m.reasoningArtifacts.indices {
            if m.reasoningArtifacts[i].originModel == nil { m.reasoningArtifacts[i].originModel = target.modelID }
            if m.reasoningArtifacts[i].originAccount == nil { m.reasoningArtifacts[i].originAccount = target.account.id }
            if let id = m.reasoningArtifacts[i].toolCallID, let fresh = renamed[id] {
                m.reasoningArtifacts[i].toolCallID = fresh
            }
        }
        return m
    }

    /// An id a provider did not really assign.
    static func needsToolCallID(_ id: String) -> Bool {
        id.isEmpty || id.range(of: #"^call_\d+$"#, options: .regularExpression) != nil
    }

    /// Applies the logical model's request defaults where the client was silent.
    func applyDefaults(_ request: CanonicalRequest, plan: RoutePlan) -> CanonicalRequest {
        var r = request
        let d = plan.defaults
        if r.temperature == nil { r.temperature = d.temperature }
        if r.topP == nil { r.topP = d.topP }
        if r.maxOutputTokens == nil { r.maxOutputTokens = d.maxOutputTokens }
        if r.reasoning == nil, let e = d.reasoningEffort { r.reasoning = ReasoningControls(effort: e) }

        if let sp = d.systemPrompt, !sp.isEmpty {
            let hasSystem = r.messages.contains { $0.role == .system || $0.role == .developer }
            switch d.systemPromptMode {
            case .replace:
                r.messages.removeAll { $0.role == .system || $0.role == .developer }
                r.messages.insert(.system(sp), at: 0)
            case .prepend:
                r.messages.insert(.system(sp), at: 0)
            case .onlyIfAbsent:
                if !hasSystem { r.messages.insert(.system(sp), at: 0) }
            }
        }
        return r
    }

    func normalize(_ error: Error) -> DerbyError {
        if let d = error as? DerbyError { return d }
        if error is CancellationError { return .cancelled() }
        return DerbyError(kind: .unknown, message: error.localizedDescription)
    }

    private func describe(_ admission: HealthRegistry.Admission) -> String {
        switch admission {
        case .allowed: return "allowed"
        case .circuitOpen(let reopensIn):
            return reopensIn > 0
                ? String(format: "circuit open, retrying in %.0fs", reopensIn)
                : "circuit open (probe already in flight)"
        case .atCapacity(let inFlight, let limit):
            return "at concurrency limit (\(inFlight)/\(limit) in flight)"
        case .rateLimited(let why): return why
        case .disabled: return "target disabled"
        }
    }

    private func admissionFailureKind(_ admission: HealthRegistry.Admission) -> FailureKind {
        switch admission {
        case .circuitOpen: return .providerDown
        case .atCapacity: return .rateLimit
        case .rateLimited: return .rateLimit
        case .disabled: return .modelUnavailable
        case .allowed: return .unknown
        }
    }

    private func skipRecord(target: ResolvedTarget, index: Int, reason: String, score: Double) -> AttemptRecord {
        AttemptRecord(id: IDGenerator.attemptID(index + 1), index: index, providerID: target.account.id,
                      providerName: target.providerName, providerKind: target.account.kind.rawValue,
                      modelID: target.modelID, targetLabel: target.label, status: .skipped,
                      startedAt: Date(), durationSeconds: 0, errorMessage: reason, routingScore: score)
    }

    private func hedgeLostRecord(target: ResolvedTarget, index: Int, score: Double, duration: Double = 0) -> AttemptRecord {
        AttemptRecord(id: IDGenerator.attemptID(index + 1), index: index, providerID: target.account.id,
                      providerName: target.providerName, providerKind: target.account.kind.rawValue,
                      modelID: target.modelID, targetLabel: target.label, status: .hedgeLost,
                      startedAt: Date(), durationSeconds: duration,
                      errorMessage: "another target answered first", routingScore: score)
    }

    private func failureRecord(target: ResolvedTarget, index: Int, error: DerbyError, duration: Double,
                               retries: Int, score: Double, circuit: CircuitState = .closed,
                               startedAt: Date = Date(), ttft: Double? = nil,
                               usage: CanonicalUsage = .zero) -> AttemptRecord {
        AttemptRecord(id: IDGenerator.attemptID(index + 1), index: index, providerID: target.account.id,
                      providerName: target.providerName, providerKind: target.account.kind.rawValue,
                      modelID: target.modelID, targetLabel: target.label,
                      status: error.kind == .clientCancelled ? .cancelled : .failed,
                      startedAt: startedAt, durationSeconds: duration, timeToFirstTokenSeconds: ttft,
                      httpStatus: error.providerStatus, failureKind: error.kind,
                      errorMessage: error.message, retryCount: retries, usage: usage,
                      circuitState: circuit, routingScore: score)
    }

    private func attemptTarget(plan: RoutePlan, label: String) -> ResolvedTarget? {
        plan.attempts.first { $0.target.label == label }?.target
    }

    private func makeRecord(meta: RequestMeta, decision: RoutingDecision, attempts: [AttemptRecord],
                            startedAt: Date, totalSeconds: Double, ttft: Double?,
                            finalTarget: ResolvedTarget?, response: CanonicalResponse?,
                            error: DerbyError?, retryCount: Int, failoverCount: Int,
                            usageOverride: CanonicalUsage? = nil, costOverride: Double? = nil,
                            midStream: Bool = false) -> RequestRecord {
        let usage = usageOverride ?? response?.usage ?? attempts.first(where: { $0.status == .success })?.usage ?? .zero
        let cost = costOverride ?? attempts.reduce(0) { $0 + $1.costUSD }
        var record = RequestRecord(
            id: meta.requestID,
            createdAt: startedAt,
            logicalModel: decision.logicalModelName,
            requestedModel: decision.logicalModelName,
            clientName: meta.clientName,
            dialect: meta.dialect.rawValue,
            streaming: meta.dialect != .embeddings && ttft != nil || midStream,
            succeeded: error == nil,
            finalProviderName: finalTarget?.providerName,
            finalProviderID: finalTarget?.account.id,
            finalModelID: finalTarget?.modelID,
            runtimeModel: finalTarget.map(RuntimeModelInfo.init(target:)),
            totalSeconds: totalSeconds,
            timeToFirstTokenSeconds: ttft,
            usage: usage,
            costUSD: cost,
            attempts: attempts,
            evaluations: decision.evaluations,
            exclusions: decision.exclusions,
            routingStrategy: decision.strategy.rawValue,
            routingExplanation: routingNarrative(decision: decision, attempts: attempts, error: error,
                                                 midStream: midStream, finalTarget: finalTarget),
            failureKind: error?.kind,
            errorMessage: error?.message,
            retryCount: retryCount,
            failoverCount: failoverCount,
            httpStatus: error?.clientHTTPStatus ?? 200)
        // The compaction that mattered is the one applied for the target that
        // answered; earlier attempts may have shortened differently or not at all.
        if let label = finalTarget?.label {
            record.compaction = attempts.last { $0.targetLabel == label }?.compaction
            record.handoff = attempts.last { $0.targetLabel == label && $0.handoff != nil }?.handoff
        } else {
            record.compaction = attempts.last { $0.compaction != nil }?.compaction
            record.handoff = attempts.last { $0.handoff != nil }?.handoff
        }
        if meta.promptLogging.storesContent {
            record.promptExcerpt = meta.promptExcerpt
            if let text = response?.message.joinedText, !text.isEmpty {
                record.responseExcerpt = meta.promptLogging.truncationLimit.map { String(text.prefix($0)) } ?? text
            }
        }
        return record
    }

    /// Human-readable "why did it end up here", built from what actually happened.
    private func routingNarrative(decision: RoutingDecision, attempts: [AttemptRecord],
                                  error: DerbyError?, midStream: Bool,
                                  finalTarget: ResolvedTarget? = nil) -> String {
        var parts = [decision.explanation]
        let failedBefore = attempts.filter { $0.status == .failed || $0.status == .skipped }
        if let success = attempts.first(where: { $0.status == .success }), !failedBefore.isEmpty {
            let reasons = failedBefore.map { a -> String in
                let why = a.failureKind?.rawValue ?? a.errorMessage ?? "unavailable"
                return "\(a.providerName) (\(why))"
            }
            parts.append("Failed over past \(reasons.joined(separator: ", ")); \(success.providerName) handled the request.")
        }
        if let error {
            if midStream {
                parts.append("The stream failed after content had already been sent (\(error.kind.rawValue)), so Derby ended it rather than switching providers mid-response.")
            } else {
                parts.append("All \(attempts.count) attempt(s) failed; last error was \(error.kind.rawValue): \(error.message)")
            }
        }
        if let label = finalTarget?.label,
           let c = attempts.last(where: { $0.targetLabel == label })?.compaction {
            parts.append(c.summary + ". The answering model did not see the full conversation.")
        }
        if let label = finalTarget?.label,
           let h = attempts.last(where: { $0.targetLabel == label })?.handoff, h.isNotable {
            parts.append("Handoff: \(h.summary).")
        }
        return parts.joined(separator: " ")
    }
}

/// Per-attempt shaping of a provider stream, so every client-visible event —
/// and the record built from them — reads the same whichever server sent it.
struct StreamShaper {
    private var splitter: ReasoningMarkup.StreamSplitter
    private var assigned: [Int: String] = [:]
    private var renamed: [String: String] = [:]
    private let modelID: String
    private let accountID: UUID

    init(target: ResolvedTarget) {
        splitter = ReasoningMarkup.StreamSplitter(prefilled: LineageTraits.for(target.lineage).thinkTagPrefilled)
        modelID = target.modelID
        accountID = target.account.id
    }

    mutating func shape(_ event: CanonicalStreamEvent) -> [CanonicalStreamEvent] {
        switch event {
        case .textDelta(let text):
            return splitter.consume(text).map(Self.event)
        case .reasoningDelta:
            // The server separates reasoning itself, so its text carries none.
            return splitter.serverSeparatesReasoning().map(Self.event) + [event]
        case .toolCallStart(let index, let id, let name):
            let resolved: String
            if Executor.needsToolCallID(id) {
                resolved = assigned[index] ?? "call_" + IDGenerator.short()
                if renamed[id] == nil { renamed[id] = resolved }
            } else {
                resolved = id
            }
            assigned[index] = resolved
            return [.toolCallStart(index: index, id: resolved, name: name)]
        case .reasoningArtifact(var artifact):
            if artifact.originModel == nil { artifact.originModel = modelID }
            if artifact.originAccount == nil { artifact.originAccount = accountID }
            if let id = artifact.toolCallID, let fresh = renamed[id] { artifact.toolCallID = fresh }
            return [.reasoningArtifact(artifact)]
        default:
            return [event]
        }
    }

    mutating func finish() -> [CanonicalStreamEvent] {
        splitter.finish().map(Self.event)
    }

    private static func event(_ piece: ReasoningMarkup.StreamSplitter.Piece) -> CanonicalStreamEvent {
        switch piece {
        case .reasoning(let text): return .reasoningDelta(text)
        case .content(let text): return .textDelta(text)
        }
    }
}
