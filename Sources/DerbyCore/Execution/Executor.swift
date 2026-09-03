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

    public init(registry: AdapterRegistry = .default,
                transport: any HTTPTransport = URLSessionTransport.shared,
                secrets: any SecretStore,
                credentials: CredentialCache,
                health: HealthRegistry,
                telemetry: any TelemetrySink = NullTelemetrySink()) {
        self.registry = registry
        self.transport = transport
        self.secrets = secrets
        self.credentials = credentials
        self.health = health
        self.telemetry = telemetry
    }

    // MARK: - Non-streaming

    public func execute(_ request: CanonicalRequest,
                        decision: RoutingDecision,
                        meta: RequestMeta) async throws -> ExecutionOutcome {
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
                                          plan: plan, deadline: deadline, meta: meta)
            } else {
                results = [await runAttemptWithRetries(planned, index: attemptIndex, request: applied,
                                                       plan: plan, deadline: deadline, meta: meta)]
            }

            for r in results {
                records.append(r.record)
                retryTotal += r.record.retryCount
            }
            attemptIndex += results.count

            if let win = results.first(where: { $0.isSuccess }), let response = win.response {
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
            await health.acquire(key, accountID: target.account.id)
            defer { Task { await self.health.release(key, accountID: target.account.id) } }

            let adapter = registry.adapter(for: target.account.kind)
            let ctx = ProviderContext(account: target.account, transport: transport, secrets: secrets,
                                      credentials: credentials, attemptTimeout: min(planned.timeout, remaining))
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
                                       request: CanonicalRequest, plan: RoutePlan,
                                       deadline: Double, meta: RequestMeta) async -> AttemptResult {
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

        await health.acquire(key, accountID: target.account.id)
        defer { Task { await self.health.release(key, accountID: target.account.id) } }

        let adapter = registry.adapter(for: target.account.kind)
        var retries = 0
        var lastError = DerbyError(kind: .unknown, message: "unknown")
        let attemptStartedAt = Date()
        let attemptT0 = Clock.monotonic

        while true {
            let remaining = deadline - Clock.monotonic
            if remaining <= 0.05 {
                lastError = .timeout("No time left in the request budget for \(target.label).")
                break
            }
            let timeout = min(planned.timeout, remaining)
            let ctx = ProviderContext(account: target.account, transport: transport, secrets: secrets,
                                      credentials: credentials, attemptTimeout: timeout)
            let callStart = Clock.monotonic
            do {
                let response = try await withDeadline(timeout,
                                                      message: "\(target.label) did not respond within \(timeout.msString)") {
                    try await adapter.execute(request, model: target.modelID, ctx: ctx)
                }
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
                                        circuitState: circuit, routingScore: planned.score)
                return .success(target, response, rec)
            } catch {
                let derby = normalize(error)
                lastError = derby
                let duration = Clock.monotonic - callStart
                await health.record(AttemptOutcome(key: key, success: false, failure: derby.kind,
                                                   totalSeconds: duration, httpStatus: derby.providerStatus))
                await health.recordFailureMessage(key, message: derby.message)

                if derby.kind == .clientCancelled { break }
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
        return .failure(target, lastError, failureRecord(target: target, index: index, error: lastError,
                                                         duration: Clock.monotonic - attemptT0,
                                                         retries: retries, score: planned.score,
                                                         circuit: circuit, startedAt: attemptStartedAt))
    }

    /// Runs two attempts with a delay between them; the first success wins and
    /// the loser is cancelled and recorded as `hedge_lost`.
    private func runHedged(primary: PlannedAttempt, hedge: PlannedAttempt,
                           primaryIndex: Int, request: CanonicalRequest, plan: RoutePlan,
                           deadline: Double, meta: RequestMeta) async -> [AttemptResult] {
        await telemetry.log(LogEntry(level: .debug, category: "executor",
                                     message: "Hedging \(primary.target.label) with \(hedge.target.label) after \(plan.hedging.delaySeconds.msString)",
                                     requestID: meta.requestID))
        return await withTaskGroup(of: (Int, AttemptResult).self) { group in
            group.addTask {
                (0, await self.runAttemptWithRetries(primary, index: primaryIndex, request: request,
                                                     plan: plan, deadline: deadline, meta: meta))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(plan.hedging.delaySeconds * 1_000_000_000))
                if Task.isCancelled {
                    return (1, .failure(hedge.target, DerbyError.cancelled("hedge not needed"),
                                        self.hedgeLostRecord(target: hedge.target, index: primaryIndex + 1,
                                                             score: hedge.score)))
                }
                return (1, await self.runAttemptWithRetries(hedge, index: primaryIndex + 1, request: request,
                                                            plan: plan, deadline: deadline, meta: meta))
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
        var lastError = DerbyError(kind: .modelUnavailable,
                                   message: "No provider attempt was made for '\(plan.logicalModelName)'.")
        let applied = applyDefaults(request, plan: plan)

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
            await health.acquire(key, accountID: target.account.id)

            let adapter = registry.adapter(for: target.account.kind)
            let attemptT0 = Clock.monotonic
            let attemptStartedAt = Date()
            var accumulator = StreamAccumulator()
            var sawContent = false
            var ttft: Double?
            var failure: DerbyError?

            do {
                let timeout = min(planned.timeout, deadline - Clock.monotonic)
                let ctx = ProviderContext(account: target.account, transport: transport, secrets: secrets,
                                          credentials: credentials, attemptTimeout: timeout)
                // Opening the stream (headers + auth) is bounded by the
                // first-token timeout; the body is bounded by the attempt timeout.
                let events = try await withDeadline(min(plan.firstTokenTimeoutSeconds, timeout),
                                                    message: "\(target.label) did not start streaming within \(plan.firstTokenTimeoutSeconds.msString)") {
                    try await adapter.stream(applied, model: target.modelID, ctx: ctx)
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
                    guard let event = next else { break }
                    accumulator.ingest(event)
                    if event.isContentBearing && !sawContent {
                        sawContent = true
                        ttft = Clock.monotonic - attemptT0
                    }
                    continuation.yield(.canonical(event))
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
                records.append(failureRecord(target: target, index: attemptIndex, error: f, duration: duration,
                                             retries: 0, score: planned.score, circuit: circuit,
                                             startedAt: attemptStartedAt, ttft: ttft, usage: usage))
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
            if response.usage.isEmpty {
                // Some OpenAI-compatible servers never report usage on a stream.
                // Derive a rough count so token and cost views are not blank,
                // flagged so the UI can show it as approximate.
                response.usage = .estimated(promptTokens: applied.estimatedPromptTokens,
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
                                         circuitState: circuit, routingScore: planned.score))
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
            totalSeconds: totalSeconds,
            timeToFirstTokenSeconds: ttft,
            usage: usage,
            costUSD: cost,
            attempts: attempts,
            evaluations: decision.evaluations,
            exclusions: decision.exclusions,
            routingStrategy: decision.strategy.rawValue,
            routingExplanation: routingNarrative(decision: decision, attempts: attempts, error: error, midStream: midStream),
            failureKind: error?.kind,
            errorMessage: error?.message,
            retryCount: retryCount,
            failoverCount: failoverCount,
            httpStatus: error?.clientHTTPStatus ?? 200)
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
                                  error: DerbyError?, midStream: Bool) -> String {
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
        return parts.joined(separator: " ")
    }
}
