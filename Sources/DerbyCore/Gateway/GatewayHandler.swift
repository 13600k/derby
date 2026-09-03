import Foundation

/// Translates HTTP into Derby's pipeline and back. Deliberately a `Sendable`
/// value (not an actor) so concurrent requests — including long-lived streams —
/// never serialize behind one another.
public struct GatewayHandler: Sendable {
    let state: ControlPlaneState
    let health: HealthRegistry
    let telemetry: TelemetryStore
    let executor: Executor
    let secrets: any SecretStore
    let router: Router
    /// Resolved once at gateway start; changing it requires a restart anyway.
    let gatewaySettings: GatewaySettings
    let localAPIKey: String?
    let promptLogging: PromptLoggingMode
    let startedAt: Date

    public init(state: ControlPlaneState, health: HealthRegistry, telemetry: TelemetryStore,
                executor: Executor, secrets: any SecretStore, router: Router = Router(),
                gatewaySettings: GatewaySettings, localAPIKey: String?,
                promptLogging: PromptLoggingMode, startedAt: Date = Date()) {
        self.state = state
        self.health = health
        self.telemetry = telemetry
        self.executor = executor
        self.secrets = secrets
        self.router = router
        self.gatewaySettings = gatewaySettings
        self.localAPIKey = localAPIKey
        self.promptLogging = promptLogging
        self.startedAt = startedAt
    }

    // MARK: - Entry point

    public func handle(_ request: HTTPServerRequest) async -> HTTPServerResponse {
        let path = normalize(request.head.path)
        let cors = corsHeaders(for: request)

        if request.head.method == "OPTIONS" {
            var h = cors
            h["access-control-allow-methods"] = "GET, POST, OPTIONS"
            h["access-control-allow-headers"] = "authorization, content-type, x-api-key, api-key, x-derby-client, openai-beta"
            h["access-control-max-age"] = "600"
            return .empty(204, headers: h)
        }

        // Unauthenticated endpoints: liveness and the human landing page.
        switch (request.head.method, path) {
        case ("GET", "/"): return landingPage(headers: cors)
        case ("GET", "/health"), ("GET", "/healthz"):
            return await healthResponse(headers: cors)
        case ("GET", "/metrics"):
            return await metricsResponse(headers: cors)
        default: break
        }

        if let failure = authorize(request) {
            return .json(401, OpenAIResponseWriter.errorObject(failure, requestID: "-"), headers: cors)
        }

        switch (request.head.method, path) {
        case ("GET", "/models"):
            return await modelsResponse(headers: cors)
        case ("GET", "/derby/status"):
            return await statusResponse(headers: cors)
        case ("POST", "/chat/completions"):
            return await chatCompletions(request, headers: cors)
        case ("POST", "/responses"):
            return await responsesAPI(request, headers: cors)
        case ("POST", "/embeddings"):
            return await embeddings(request, headers: cors)
        case ("POST", "/completions"):
            return .json(400, OpenAIResponseWriter.errorObject(
                DerbyError.invalid("The legacy /v1/completions endpoint is not supported. Use /v1/chat/completions."),
                requestID: "-"), headers: cors)
        default:
            return .json(404, OpenAIResponseWriter.errorObject(
                DerbyError(kind: .invalidRequest, message: "Unknown endpoint \(request.head.path).", providerStatus: 404),
                requestID: "-"), headers: cors)
        }
    }

    /// Accepts both `/v1/...` and bare paths so clients that append their own
    /// version prefix and those that do not both work.
    private func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/v1/") { p = String(p.dropFirst(3)) }
        else if p == "/v1" { p = "/" }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func corsHeaders(for request: HTTPServerRequest) -> [String: String] {
        guard let origin = request.head.header("origin") else { return [:] }
        if gatewaySettings.allowedOrigins.isEmpty || gatewaySettings.allowedOrigins.contains(origin) {
            return ["access-control-allow-origin": origin, "vary": "origin"]
        }
        return [:]
    }

    private func authorize(_ request: HTTPServerRequest) -> DerbyError? {
        guard gatewaySettings.requireAPIKey else { return nil }
        // Authentication is required but no key could be loaded (for example the
        // Keychain was unavailable). Refuse everything rather than silently
        // serving an unauthenticated gateway.
        guard let expected = localAPIKey, !expected.isEmpty else {
            return DerbyError(kind: .authentication,
                              message: "Derby requires an API key but could not load one from the Keychain. Open Derby → Settings to regenerate it, or turn off 'Require the local API key'.",
                              providerStatus: 401)
        }
        let presented: String? = {
            if let auth = request.head.header("authorization") {
                if auth.lowercased().hasPrefix("bearer ") { return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                return auth.trimmingCharacters(in: .whitespaces)
            }
            return request.head.header("x-api-key") ?? request.head.header("api-key")
        }()
        guard let presented, !presented.isEmpty else {
            return DerbyError(kind: .authentication,
                              message: "Missing API key. Send the Derby local key as 'Authorization: Bearer <key>'. Find it in Derby → Settings.",
                              providerStatus: 401)
        }
        // Constant-time-ish comparison; keys are short and local, but there is no
        // reason to leak length or prefix information.
        let a = Array(presented.utf8), b = Array(expected.utf8)
        var diff = a.count ^ b.count
        for i in 0..<min(a.count, b.count) { diff |= Int(a[i] ^ b[i]) }
        if diff != 0 {
            return DerbyError(kind: .authentication,
                              message: "Invalid API key for the Derby gateway.", providerStatus: 401)
        }
        return nil
    }

    // MARK: - Snapshot helper

    private func snapshot() async -> RoutingSnapshot {
        let h = await health.snapshot()
        return await state.snapshot(health: h)
    }

    // MARK: - Endpoints

    private func modelsResponse(headers: [String: String]) async -> HTTPServerResponse {
        .json(200, OpenAIResponseWriter.modelsList(await snapshot()), headers: headers)
    }

    private func healthResponse(headers: [String: String]) async -> HTTPServerResponse {
        let snap = await snapshot()
        var providers: [JSONValue] = []
        for (_, account) in snap.accounts.sorted(by: { $0.value.name < $1.value.name }) {
            let states = account.models.map { snap.health(for: TargetKey(providerID: account.id, modelID: $0.modelID)) }
            let worst = states.map(\.state).min { a, b in a.scoreValue > b.scoreValue } ?? .unknown
            providers.append(.object([
                "name": .string(account.name),
                "kind": .string(account.kind.rawValue),
                "enabled": .bool(account.enabled),
                "state": .string(worst.rawValue),
                "open_circuits": .number(Double(states.filter { $0.circuit == .open }.count)),
            ]))
        }
        return .json(200, .object([
            "status": .string("ok"),
            "uptime_seconds": .number(Date().timeIntervalSince(startedAt).rounded()),
            "logical_models": .array(snap.logicalModelNames.map { .string($0) }),
            "providers": .array(providers),
            "snapshot_version": .number(Double(snap.version)),
        ]), headers: headers)
    }

    private func statusResponse(headers: [String: String]) async -> HTTPServerResponse {
        let snap = await snapshot()
        var models: [JSONValue] = []
        for lm in snap.logicalModels.values.sorted(by: { $0.name < $1.name }) {
            models.append(.object([
                "name": .string(lm.name),
                "strategy": .string(lm.definition.policy.strategy.rawValue),
                "targets": .array(lm.targets.map { t in
                    let h = snap.health(for: t.key)
                    return .object([
                        "provider": .string(t.providerName),
                        "model": .string(t.modelID),
                        "enabled": .bool(t.unavailableReason == nil),
                        "health": .string(h.state.rawValue),
                        "circuit": .string(h.circuit.rawValue),
                        "p50_ms": h.p50Seconds.map { .number(Double($0.msRounded)) } ?? .null,
                    ])
                }),
            ]))
        }
        return .json(200, .object(["logical_models": .array(models),
                                   "snapshot_version": .number(Double(snap.version))]), headers: headers)
    }

    private func metricsResponse(headers: [String: String]) async -> HTTPServerResponse {
        let snap = await snapshot()
        let usage = await telemetry.usage(window: .today)
        var lines: [String] = []
        func metric(_ name: String, _ help: String, _ type: String, _ samples: [(String, Double)]) {
            lines.append("# HELP \(name) \(help)")
            lines.append("# TYPE \(name) \(type)")
            for (labels, value) in samples {
                lines.append(labels.isEmpty ? "\(name) \(value)" : "\(name){\(labels)} \(value)")
            }
        }
        metric("derby_requests_total", "Requests handled today.", "counter", [("", Double(usage.totalRequests))])
        metric("derby_requests_failed_total", "Failed requests today.", "counter", [("", Double(usage.failures))])
        metric("derby_failovers_total", "Failovers today.", "counter", [("", Double(usage.failovers))])
        metric("derby_retries_total", "Retries today.", "counter", [("", Double(usage.retries))])
        metric("derby_cost_usd_total", "Estimated spend today.", "counter", [("", usage.costUSD)])
        metric("derby_tokens_total", "Tokens today.", "counter",
               [("direction=\"input\"", Double(usage.inputTokens)), ("direction=\"output\"", Double(usage.outputTokens))])

        var healthSamples: [(String, Double)] = []
        var circuitSamples: [(String, Double)] = []
        var latencySamples: [(String, Double)] = []
        for (key, h) in snap.health {
            let provider = snap.accounts[key.providerID]?.name ?? key.providerID.uuidString
            let labels = "provider=\"\(escape(provider))\",model=\"\(escape(key.modelID))\""
            healthSamples.append((labels, h.successRate))
            circuitSamples.append((labels, h.circuit == .open ? 1 : (h.circuit == .halfOpen ? 0.5 : 0)))
            if let p = h.p50Seconds { latencySamples.append((labels, p)) }
        }
        metric("derby_target_success_rate", "Rolling success rate per target.", "gauge", healthSamples)
        metric("derby_target_circuit_open", "1 when a target's circuit is open.", "gauge", circuitSamples)
        metric("derby_target_latency_p50_seconds", "Rolling p50 latency per target.", "gauge", latencySamples)

        var h = headers
        h["content-type"] = "text/plain; version=0.0.4; charset=utf-8"
        return .data(status: 200, headers: h, body: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func landingPage(headers: [String: String]) -> HTTPServerResponse {
        let endpoint = gatewaySettings.endpointURL
        let body = """
        Derby — local AI model routing gateway

        OpenAI-compatible base URL:
          \(endpoint)

        Endpoints:
          GET  \(endpoint)/models
          POST \(endpoint)/chat/completions
          POST \(endpoint)/responses
          POST \(endpoint)/embeddings
          GET  /health
          GET  /metrics

        Authentication: \(gatewaySettings.requireAPIKey ? "send the Derby local key as 'Authorization: Bearer <key>' (Derby → Settings)" : "disabled")

        Ask for a logical model name (for example "coding") as the `model` field.
        """
        var h = headers
        h["content-type"] = "text/plain; charset=utf-8"
        return .data(status: 200, headers: h, body: Data(body.utf8))
    }

    // MARK: - Chat completions

    private func chatCompletions(_ request: HTTPServerRequest, headers: [String: String]) async -> HTTPServerResponse {
        let requestID = IDGenerator.requestID()
        guard let json = request.bodyJSON else {
            return .json(400, OpenAIResponseWriter.errorObject(
                .invalid("Request body must be valid JSON."), requestID: requestID), headers: headers)
        }
        let canonical: CanonicalRequest
        do { canonical = try OpenAIRequestParser.parseChatCompletions(json) }
        catch {
            let e = error as? DerbyError ?? DerbyError.invalid(error.localizedDescription)
            return .json(e.clientHTTPStatus, OpenAIResponseWriter.errorObject(e, requestID: requestID), headers: headers)
        }
        return await run(canonical, request: request, requestID: requestID, headers: headers, dialect: .chatCompletions)
    }

    private func responsesAPI(_ request: HTTPServerRequest, headers: [String: String]) async -> HTTPServerResponse {
        let requestID = IDGenerator.requestID()
        guard let json = request.bodyJSON else {
            return .json(400, OpenAIResponseWriter.errorObject(
                .invalid("Request body must be valid JSON."), requestID: requestID), headers: headers)
        }
        let canonical: CanonicalRequest
        do { canonical = try OpenAIRequestParser.parseResponses(json) }
        catch {
            let e = error as? DerbyError ?? DerbyError.invalid(error.localizedDescription)
            return .json(e.clientHTTPStatus, OpenAIResponseWriter.errorObject(e, requestID: requestID), headers: headers)
        }
        return await run(canonical, request: request, requestID: requestID, headers: headers, dialect: .responses)
    }

    private func run(_ canonical: CanonicalRequest, request: HTTPServerRequest, requestID: String,
                     headers: [String: String], dialect: APIDialect) async -> HTTPServerResponse {
        let snap = await snapshot()
        let cursor = await state.nextCursor(for: canonical.requestedModel)
        let decision: RoutingDecision
        do {
            decision = try router.route(RoutingRequest(canonical), snapshot: snap, roundRobinCursor: cursor)
        } catch {
            let e = error as? DerbyError ?? DerbyError(kind: .unknown, message: error.localizedDescription)
            await telemetry.log(LogEntry(level: .warn, category: "routing",
                                         message: e.message, requestID: requestID,
                                         fields: ["model": canonical.requestedModel]))
            // Even an unroutable request is recorded, so the inspector can show why.
            await telemetry.record(RequestRecord(id: requestID, logicalModel: canonical.requestedModel,
                                                 requestedModel: canonical.requestedModel,
                                                 clientName: request.clientName, dialect: dialect.rawValue,
                                                 streaming: canonical.stream, succeeded: false,
                                                 routingExplanation: e.message, failureKind: e.kind,
                                                 errorMessage: e.message, httpStatus: e.clientHTTPStatus))
            return .json(e.clientHTTPStatus, OpenAIResponseWriter.errorObject(e, requestID: requestID), headers: headers)
        }

        let meta = RequestMeta(requestID: requestID, clientName: request.clientName, dialect: dialect,
                               promptLogging: promptLogging,
                               promptExcerpt: promptExcerpt(canonical))

        if canonical.stream {
            return streamingResponse(canonical, decision: decision, meta: meta, headers: headers, dialect: dialect)
        }

        do {
            let outcome = try await executor.execute(canonical, decision: decision, meta: meta)
            let payload = dialect == .responses
                ? OpenAIResponseWriter.responsesObject(outcome.response, record: outcome.record)
                : OpenAIResponseWriter.chatCompletion(outcome.response, record: outcome.record)
            var h = headers
            h["x-derby-request-id"] = outcome.record.id
            h["x-derby-provider"] = outcome.target.providerName
            h["x-derby-model"] = outcome.target.modelID
            return .json(200, payload, headers: h)
        } catch {
            let e = error as? DerbyError ?? DerbyError(kind: .unknown, message: error.localizedDescription)
            var h = headers
            h["x-derby-request-id"] = requestID
            return .json(e.clientHTTPStatus, OpenAIResponseWriter.errorObject(e, requestID: requestID), headers: h)
        }
    }

    private func promptExcerpt(_ r: CanonicalRequest) -> String? {
        guard promptLogging.storesContent else { return nil }
        let text = r.messages.map { "\($0.role.rawValue): \($0.joinedText)" }.joined(separator: "\n")
        if let limit = promptLogging.truncationLimit { return String(text.prefix(limit)) }
        return text
    }

    // MARK: - Streaming

    private func streamingResponse(_ canonical: CanonicalRequest, decision: RoutingDecision,
                                   meta: RequestMeta, headers: [String: String],
                                   dialect: APIDialect) -> HTTPServerResponse {
        var h = headers
        h["x-derby-request-id"] = meta.requestID
        let executor = self.executor
        let telemetry = self.telemetry

        return .sse(headers: h) { writer in
            var emitter = OpenAIResponseWriter.ChatChunkEmitter(requestID: meta.requestID,
                                                                model: decision.plan.attempts.first?.target.modelID
                                                                    ?? decision.logicalModelName)
            var lastRecord: RequestRecord?
            var pendingUsage: CanonicalUsage?
            var sentAnything = false
            var responsesTextIndex = 0

            func send(_ value: JSONValue) async throws {
                try await writer.writeSSE(data: value.compactJSONString)
                sentAnything = true
            }

            do {
                for try await event in executor.stream(canonical, decision: decision, meta: meta) {
                    switch event {
                    case .attemptStarted(let target, _):
                        // The model name is only known once a target is chosen.
                        emitter.model = target.modelID
                        if dialect == .responses {
                            try await writer.writeSSE(event: "response.created", data: JSONValue.object([
                                "type": .string("response.created"),
                                "response": .object(["id": .string("resp_\(meta.requestID)"),
                                                     "status": .string("in_progress"),
                                                     "model": .string(target.modelID)]),
                            ]).compactJSONString)
                            sentAnything = true
                        } else if let role = emitter.roleChunkIfNeeded() {
                            try await send(role)
                        }

                    case .canonical(let c):
                        switch c {
                        case .start:
                            break
                        case .textDelta(let t):
                            if dialect == .responses {
                                try await writer.writeSSE(event: "response.output_text.delta", data: JSONValue.object([
                                    "type": .string("response.output_text.delta"),
                                    "output_index": .number(0),
                                    "content_index": .number(Double(responsesTextIndex)),
                                    "delta": .string(t),
                                ]).compactJSONString)
                                responsesTextIndex += 1
                                sentAnything = true
                            } else {
                                try await send(emitter.textChunk(t))
                            }
                        case .reasoningDelta(let t):
                            if dialect == .responses {
                                try await writer.writeSSE(event: "response.reasoning_summary_text.delta",
                                                          data: JSONValue.object([
                                                              "type": .string("response.reasoning_summary_text.delta"),
                                                              "delta": .string(t),
                                                          ]).compactJSONString)
                                sentAnything = true
                            } else {
                                try await send(emitter.reasoningChunk(t))
                            }
                        case .toolCallStart(let index, let id, let name):
                            if dialect == .responses {
                                try await writer.writeSSE(event: "response.output_item.added", data: JSONValue.object([
                                    "type": .string("response.output_item.added"),
                                    "output_index": .number(Double(index)),
                                    "item": .object(["type": .string("function_call"),
                                                     "call_id": .string(id), "name": .string(name)]),
                                ]).compactJSONString)
                                sentAnything = true
                            } else {
                                try await send(emitter.toolCallStartChunk(index: index, id: id, name: name))
                            }
                        case .toolCallArgumentsDelta(let index, let delta):
                            if dialect == .responses {
                                try await writer.writeSSE(event: "response.function_call_arguments.delta",
                                                          data: JSONValue.object([
                                                              "type": .string("response.function_call_arguments.delta"),
                                                              "output_index": .number(Double(index)),
                                                              "delta": .string(delta),
                                                          ]).compactJSONString)
                                sentAnything = true
                            } else {
                                try await send(emitter.toolCallArgsChunk(index: index, delta: delta))
                            }
                        case .usage(let u):
                            pendingUsage = u
                        case .finish(let reason):
                            if dialect != .responses { try await send(emitter.finishChunk(reason)) }
                        }

                    case .finished(let record):
                        lastRecord = record
                        if dialect == .responses {
                            let response = CanonicalResponse(id: record.id, model: record.finalModelID ?? emitter.model,
                                                             message: .assistant(""), usage: record.usage)
                            var obj = OpenAIResponseWriter.responsesObject(response, record: record)
                            obj = obj.merging(.object(["output": .array([])]))
                            try await writer.writeSSE(event: "response.completed", data: JSONValue.object([
                                "type": .string("response.completed"),
                                "response": obj,
                            ]).compactJSONString)
                        } else {
                            if let u = pendingUsage ?? (record.usage.isEmpty ? nil : record.usage) {
                                try await send(emitter.usageChunk(u, record: record))
                            }
                            try await writer.writeSSEDone()
                        }

                    case .failed(let error, let record):
                        lastRecord = record
                        // Content already reached the client; surface the error
                        // in-band and close, rather than silently truncating.
                        try? await writer.writeSSE(data: OpenAIResponseWriter
                            .errorObject(error, requestID: meta.requestID, record: record).compactJSONString)
                        try? await writer.writeSSEDone()
                    }
                }
            } catch let error as DerbyError where error.kind == .clientCancelled {
                await telemetry.log(LogEntry(level: .debug, category: "gateway",
                                             message: "Client disconnected mid-stream.", requestID: meta.requestID))
            } catch {
                let e = error as? DerbyError ?? DerbyError(kind: .unknown, message: error.localizedDescription)
                // Nothing sent yet: the client can still be given a clean error.
                try? await writer.writeSSE(data: OpenAIResponseWriter
                    .errorObject(e, requestID: meta.requestID, record: lastRecord).compactJSONString)
                try? await writer.writeSSEDone()
                _ = sentAnything
            }
            await writer.finish()
        }
    }

    // MARK: - Embeddings

    private func embeddings(_ request: HTTPServerRequest, headers: [String: String]) async -> HTTPServerResponse {
        let requestID = IDGenerator.requestID()
        guard let json = request.bodyJSON else {
            return .json(400, OpenAIResponseWriter.errorObject(
                .invalid("Request body must be valid JSON."), requestID: requestID), headers: headers)
        }
        let canonical: CanonicalEmbeddingRequest
        do { canonical = try OpenAIRequestParser.parseEmbeddings(json) }
        catch {
            let e = error as? DerbyError ?? DerbyError.invalid(error.localizedDescription)
            return .json(e.clientHTTPStatus, OpenAIResponseWriter.errorObject(e, requestID: requestID), headers: headers)
        }

        let snap = await snapshot()
        let cursor = await state.nextCursor(for: canonical.requestedModel)
        do {
            let decision = try router.route(RoutingRequest(canonical), snapshot: snap, roundRobinCursor: cursor)
            let meta = RequestMeta(requestID: requestID, clientName: request.clientName,
                                   dialect: .embeddings, promptLogging: promptLogging)
            let outcome = try await executor.embed(canonical, decision: decision, meta: meta)
            let data: [JSONValue] = outcome.response.vectors.enumerated().map { i, v in
                .object(["object": .string("embedding"), "index": .number(Double(i)),
                         "embedding": .array(v.map { .number($0) })])
            }
            var h = headers
            h["x-derby-request-id"] = requestID
            h["x-derby-provider"] = outcome.target.providerName
            return .json(200, .object([
                "object": .string("list"),
                "data": .array(data),
                "model": .string(outcome.response.model),
                "usage": .object(["prompt_tokens": .number(Double(outcome.response.usage.inputTokens)),
                                  "total_tokens": .number(Double(outcome.response.usage.totalTokens))]),
                "x_derby": OpenAIResponseWriter.derbyMetadata(outcome.record),
            ]), headers: h)
        } catch {
            let e = error as? DerbyError ?? DerbyError(kind: .unknown, message: error.localizedDescription)
            return .json(e.clientHTTPStatus, OpenAIResponseWriter.errorObject(e, requestID: requestID), headers: headers)
        }
    }
}
