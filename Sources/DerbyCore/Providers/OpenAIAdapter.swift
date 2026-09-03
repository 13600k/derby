import Foundation

/// Per-endpoint deviations from OpenAI's spec. Declarative so support for a new
/// OpenAI-compatible service is a data change, not a new adapter.
public struct OpenAIQuirks: Sendable {
    public enum AuthStyle: Sendable { case bearer, apiKeyHeader(String), queryParam(String), none }
    public enum PathStyle: Sendable { case standard, azureDeployment }

    public var authStyle: AuthStyle = .bearer
    public var pathStyle: PathStyle = .standard
    /// Reasoning-era OpenAI models require `max_completion_tokens`.
    public var prefersMaxCompletionTokens = false
    public var supportsParallelToolCalls = true
    public var supportsJSONSchema = true
    public var supportsStreamOptions = true
    public var supportsPenalties = true
    public var supportsSeed = true
    public var supportsReasoningEffort = false
    /// Some servers 400 on unknown fields; keep the payload minimal for those.
    public var strictSchema = false
    public var listModelsPath = "models"
    public var chatPath = "chat/completions"
    public var embeddingsPath = "embeddings"
    public var defaultHeaders: [String: String] = [:]

    public init() {}

    public static func forKind(_ kind: ProviderKind, account: ProviderAccount) -> OpenAIQuirks {
        var q = OpenAIQuirks()
        switch kind {
        case .openai:
            q.supportsReasoningEffort = true
        case .azureOpenAI:
            q.authStyle = .apiKeyHeader("api-key")
            q.pathStyle = .azureDeployment
            q.listModelsPath = "openai/models"
            q.supportsReasoningEffort = true
        case .openrouter:
            q.defaultHeaders = ["http-referer": "https://github.com/derby-gateway",
                                "x-title": "Derby"]
            q.supportsReasoningEffort = true
        case .groq:
            q.supportsPenalties = true
            q.supportsJSONSchema = true
        case .mistral, .deepseek, .together, .fireworks, .xai:
            break
        case .qwen:
            q.supportsParallelToolCalls = false
        case .ollama:
            // Current Ollama builds honour stream_options and report usage on the
            // final chunk; older ones simply ignore the field rather than failing.
            q.supportsStreamOptions = true
            q.supportsParallelToolCalls = false
            q.supportsJSONSchema = true
            q.authStyle = .none
            q.strictSchema = true
        case .lmStudio, .llamaCpp, .localai, .sglang, .vllm:
            q.supportsStreamOptions = (kind == .vllm || kind == .sglang || kind == .lmStudio)
            q.supportsParallelToolCalls = false
            q.authStyle = .none
            q.strictSchema = (kind == .llamaCpp || kind == .localai)
        case .openAICompatible:
            // Conservative defaults: unknown servers get the smallest viable body.
            q.supportsStreamOptions = false
            q.supportsParallelToolCalls = false
            q.strictSchema = true
        default:
            break
        }
        // An account with a key always sends it, even for kinds that default to none.
        if case .none = q.authStyle, !account.auth.secretRefs.isEmpty { q.authStyle = .bearer }
        if case .apiKey = account.auth, case .none = q.authStyle { q.authStyle = .bearer }
        return q
    }
}

/// Speaks the OpenAI HTTP dialect. Used for OpenAI itself, Azure, every
/// OpenAI-compatible aggregator, and every local server.
public struct OpenAIAdapter: ProviderAdapter {
    public let family: AdapterFamily = .openai
    public init() {}

    private func quirks(_ ctx: ProviderContext) -> OpenAIQuirks {
        OpenAIQuirks.forKind(ctx.account.kind, account: ctx.account)
    }

    // MARK: - Auth

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        var auth = ResolvedAuth()
        let q = quirks(ctx)
        for (k, v) in q.defaultHeaders { auth.headers[k] = v }

        switch ctx.account.auth {
        case .none:
            break
        case .apiKey(let ref):
            let key = try requireSecret(ref, ctx: ctx, label: "API key")
            switch q.authStyle {
            case .bearer, .none: auth.headers["authorization"] = "Bearer \(key)"
            case .apiKeyHeader(let name): auth.headers[name] = key
            case .queryParam(let name): auth.queryItems[name] = key
            }
        case .customHeader(let name, let ref, let prefix):
            let key = try requireSecret(ref, ctx: ctx, label: "credential")
            auth.headers[name.lowercased()] = prefix.isEmpty ? key : "\(prefix)\(key)"
        case .cli(let source, let allowRefresh):
            // Qwen's OAuth flow yields an OpenAI-compatible endpoint + bearer token.
            let cred = try await ctx.credentials.credential(for: source, allowRefresh: allowRefresh,
                                                             home: ctx.account.credentialHomeURL)
            auth.headers["authorization"] = "Bearer \(cred.accessToken)"
            if let r = cred.resourceURL, ctx.account.baseURLOverride == nil {
                auth.baseURLOverride = r.hasSuffix("/v1") ? r : r.trimmedTrailingSlash + "/v1"
            }
        case .awsSigV4:
            throw DerbyError(kind: .invalidRequest,
                             message: "AWS SigV4 credentials cannot be used with an OpenAI-compatible endpoint.")
        }
        if ctx.account.kind == .azureOpenAI {
            auth.queryItems["api-version"] = ctx.account.apiVersion ?? "2024-10-21"
        }
        return auth
    }

    // MARK: - Discovery

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        let q = quirks(ctx)
        let auth = try await authenticate(ctx)
        let u = try url(ctx, path: q.listModelsPath, auth: auth)
        let req = OutboundRequest(url: u, method: "GET", headers: headers(ctx, auth: auth),
                                  timeout: min(ctx.account.requestTimeoutSeconds, 30),
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: "")
        }
        guard let json = resp.bodyJSON else {
            throw DerbyError(kind: .transient, message: "Model list was not valid JSON.")
        }
        let items = json["data"]?.arrayValue ?? json.arrayValue ?? []
        var out: [DiscoveredModel] = []
        for item in items {
            guard let id = item["id"]?.stringValue ?? item["name"]?.stringValue else { continue }
            var caps = ModelCatalog.metadata(for: id, kind: ctx.account.kind).capabilities
            // Some servers publish richer metadata than our catalog knows.
            if let ctx2 = item["context_length"]?.intValue ?? item["context_window"]?.intValue {
                caps.contextWindow = ctx2
                caps.source = .discovered
            }
            if let arch = item["architecture"]?["input_modalities"]?.arrayValue {
                if arch.contains(where: { $0.stringValue == "image" }) { caps.flags.insert(.vision) }
                caps.source = .discovered
            }
            if let params = item["supported_parameters"]?.arrayValue {
                if params.contains(where: { $0.stringValue == "tools" }) { caps.flags.insert(.tools) }
            }
            out.append(DiscoveredModel(id: id, displayName: item["name"]?.stringValue, capabilities: caps))
        }
        return out.sorted { $0.id < $1.id }
    }

    // MARK: - Execute

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        let q = quirks(ctx)
        let auth = try await authenticate(ctx)
        let body = try buildChatBody(request, model: model, quirks: q, stream: false)
        let u = try chatURL(ctx, model: model, quirks: q, auth: auth)
        let req = OutboundRequest(url: u, method: "POST", headers: headers(ctx, auth: auth),
                                  body: try encode(body), timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: model)
        }
        guard let json = resp.bodyJSON else {
            throw DerbyError(kind: .transient, message: "Provider returned a non-JSON response.",
                             providerStatus: resp.status,
                             detail: String(resp.bodyText.prefix(300)))
        }
        return try parseChatResponse(json, fallbackModel: model)
    }

    public func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let q = quirks(ctx)
        let auth = try await authenticate(ctx)
        let body = try buildChatBody(request, model: model, quirks: q, stream: true)
        let u = try chatURL(ctx, model: model, quirks: q, auth: auth)
        var h = headers(ctx, auth: auth)
        h["accept"] = "text/event-stream"
        let req = OutboundRequest(url: u, method: "POST", headers: h, body: try encode(body),
                                  timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let start = try await ctx.transport.stream(req)
        guard (200..<300).contains(start.status) else {
            throw classifyError(status: start.status, headers: start.headers,
                                body: start.errorBody ?? Data(), model: model)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedStart = false
                var usage = CanonicalUsage.zero
                var finish: CanonicalFinishReason?
                do {
                    for try await event in start.events {
                        if event.isDone { break }
                        guard let json = event.json else { continue }
                        if let err = json["error"], !err.isNull {
                            throw errorFromBody(err, status: 200, model: model)
                        }
                        if !emittedStart {
                            emittedStart = true
                            continuation.yield(.start(id: json["id"]?.stringValue ?? IDGenerator.requestID(),
                                                      model: json["model"]?.stringValue ?? model))
                        }
                        if let u = json["usage"], !u.isNull {
                            usage = parseUsage(u)
                        }
                        guard let choice = json["choices"]?[0] else { continue }
                        if let delta = choice["delta"] {
                            if let c = delta["content"] {
                                if let s = c.stringValue, !s.isEmpty { continuation.yield(.textDelta(s)) }
                                else if let parts = c.arrayValue {
                                    for p in parts { if let t = p["text"]?.stringValue, !t.isEmpty { continuation.yield(.textDelta(t)) } }
                                }
                            }
                            // Reasoning goes by several names across compatible servers.
                            for key in ["reasoning_content", "reasoning", "thinking"] {
                                if let r = delta[key]?.stringValue, !r.isEmpty {
                                    continuation.yield(.reasoningDelta(r)); break
                                }
                            }
                            if let calls = delta["tool_calls"]?.arrayValue {
                                for call in calls {
                                    let idx = call["index"]?.intValue ?? 0
                                    let id = call["id"]?.stringValue ?? ""
                                    let name = call["function"]?["name"]?.stringValue ?? ""
                                    if !id.isEmpty || !name.isEmpty {
                                        continuation.yield(.toolCallStart(index: idx, id: id, name: name))
                                    }
                                    if let args = call["function"]?["arguments"]?.stringValue, !args.isEmpty {
                                        continuation.yield(.toolCallArgumentsDelta(index: idx, delta: args))
                                    }
                                }
                            }
                        }
                        if let fr = choice["finish_reason"]?.stringValue {
                            finish = mapFinishReason(fr)
                        }
                    }
                    if !usage.isEmpty { continuation.yield(.usage(usage)) }
                    continuation.yield(.finish(finish ?? .stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Embeddings

    public func embed(_ request: CanonicalEmbeddingRequest, model: String, ctx: ProviderContext) async throws
        -> CanonicalEmbeddingResponse {
        let q = quirks(ctx)
        let auth = try await authenticate(ctx)
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(request.inputs.map { .string($0) }),
        ]
        if let d = request.dimensions { body["dimensions"] = .number(Double(d)) }
        if let f = request.encodingFormat { body["encoding_format"] = .string(f) }
        if let u = request.user { body["user"] = .string(u) }

        let path = ctx.account.kind == .azureOpenAI
            ? "openai/deployments/\(model)/embeddings"
            : q.embeddingsPath
        let u = try url(ctx, path: path, auth: auth)
        let req = OutboundRequest(url: u, method: "POST", headers: headers(ctx, auth: auth),
                                  body: try encode(.object(body)), timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: model)
        }
        guard let json = resp.bodyJSON, let data = json["data"]?.arrayValue else {
            throw DerbyError(kind: .transient, message: "Embeddings response was malformed.")
        }
        let vectors: [[Double]] = data.compactMap { item in
            item["embedding"]?.arrayValue?.compactMap { $0.doubleValue }
        }
        return CanonicalEmbeddingResponse(model: json["model"]?.stringValue ?? model,
                                          vectors: vectors,
                                          usage: parseUsage(json["usage"] ?? .null))
    }

    // MARK: - Body construction

    private func chatURL(_ ctx: ProviderContext, model: String, quirks q: OpenAIQuirks, auth: ResolvedAuth) throws -> URL {
        switch q.pathStyle {
        case .standard:
            return try url(ctx, path: q.chatPath, auth: auth)
        case .azureDeployment:
            return try url(ctx, path: "openai/deployments/\(model)/chat/completions", auth: auth)
        }
    }

    private func encode(_ v: JSONValue) throws -> Data {
        try JSONEncoder().encode(v)
    }

    func buildChatBody(_ r: CanonicalRequest, model: String, quirks q: OpenAIQuirks, stream: Bool) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(r.messages.map { encodeMessage($0) }),
        ]
        if stream {
            body["stream"] = .bool(true)
            if q.supportsStreamOptions {
                body["stream_options"] = .object(["include_usage": .bool(true)])
            }
        }
        if let t = r.temperature { body["temperature"] = .number(t) }
        if let p = r.topP { body["top_p"] = .number(p) }
        if let m = r.maxOutputTokens {
            body[q.prefersMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = .number(Double(m))
        }
        if !r.stop.isEmpty { body["stop"] = .array(r.stop.map { .string($0) }) }
        if q.supportsSeed, let s = r.seed { body["seed"] = .number(Double(s)) }
        if q.supportsPenalties {
            if let f = r.frequencyPenalty { body["frequency_penalty"] = .number(f) }
            if let p = r.presencePenalty { body["presence_penalty"] = .number(p) }
        }
        if let n = r.n, n != 1 { body["n"] = .number(Double(n)) }
        if let u = r.user { body["user"] = .string(u) }

        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { t in
                var fn: [String: JSONValue] = ["name": .string(t.name), "parameters": t.parameters]
                if let d = t.description { fn["description"] = .string(d) }
                if q.supportsJSONSchema, let s = t.strict { fn["strict"] = .bool(s) }
                return .object(["type": .string("function"), "function": .object(fn)])
            })
            if let choice = r.toolChoice {
                switch choice {
                case .auto: body["tool_choice"] = .string("auto")
                case .none: body["tool_choice"] = .string("none")
                case .required: body["tool_choice"] = .string("required")
                case .function(let name):
                    body["tool_choice"] = .object(["type": .string("function"),
                                                   "function": .object(["name": .string(name)])])
                }
            }
            if q.supportsParallelToolCalls, let p = r.parallelToolCalls {
                body["parallel_tool_calls"] = .bool(p)
            }
        }

        if let rf = r.responseFormat {
            switch rf {
            case .text:
                break
            case .jsonObject:
                body["response_format"] = .object(["type": .string("json_object")])
            case .jsonSchema(let name, let schema, let strict):
                if q.supportsJSONSchema {
                    body["response_format"] = .object([
                        "type": .string("json_schema"),
                        "json_schema": .object(["name": .string(name),
                                                "schema": schema,
                                                "strict": .bool(strict)]),
                    ])
                } else {
                    body["response_format"] = .object(["type": .string("json_object")])
                }
            }
        }

        if q.supportsReasoningEffort, let reasoning = r.reasoning, let effort = reasoning.effort {
            body["reasoning_effort"] = .string(effort.standardOpenAIValue)
        }

        // Escape hatch: anything the user configured for this family wins.
        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["openai"] {
            result = result.merging(ext)
        }
        return result
    }

    private func encodeMessage(_ m: CanonicalMessage) -> JSONValue {
        var out: [String: JSONValue] = ["role": .string(m.role == .developer ? "developer" : m.role.rawValue)]
        if let n = m.name { out["name"] = .string(n) }

        switch m.role {
        case .tool:
            out["tool_call_id"] = .string(m.toolCallID ?? "")
            out["content"] = .string(m.joinedText)
        case .assistant:
            let text = m.joinedText
            out["content"] = text.isEmpty ? .null : .string(text)
            if !m.toolCalls.isEmpty {
                out["tool_calls"] = .array(m.toolCalls.map { tc in
                    .object(["id": .string(tc.id), "type": .string("function"),
                             "function": .object(["name": .string(tc.name),
                                                  "arguments": .string(tc.argumentsJSON.isEmpty ? "{}" : tc.argumentsJSON)])])
                })
            }
        default:
            // Multimodal content must use the array form; plain text uses the
            // string form, which every compatible server accepts.
            if m.content.count == 1, case .text(let t) = m.content[0] {
                out["content"] = .string(t)
            } else if m.content.isEmpty {
                out["content"] = .string("")
            } else {
                out["content"] = .array(m.content.map { part in
                    switch part {
                    case .text(let t):
                        return .object(["type": .string("text"), "text": .string(t)])
                    case .refusal(let t):
                        return .object(["type": .string("text"), "text": .string(t)])
                    case .image(let img):
                        var iu: [String: JSONValue] = ["url": .string(img.asDataURI)]
                        if let d = img.detail { iu["detail"] = .string(d) }
                        return .object(["type": .string("image_url"), "image_url": .object(iu)])
                    case .audio(let a):
                        return .object(["type": .string("input_audio"),
                                        "input_audio": .object(["data": .string(a.base64),
                                                                "format": .string(a.format)])])
                    }
                })
            }
        }
        return .object(out)
    }

    // MARK: - Response parsing

    func parseChatResponse(_ json: JSONValue, fallbackModel: String) throws -> CanonicalResponse {
        if let err = json["error"], !err.isNull {
            throw errorFromBody(err, status: 200, model: fallbackModel)
        }
        guard let choice = json["choices"]?[0] else {
            throw DerbyError(kind: .transient, message: "Provider response contained no choices.",
                             detail: String(json.compactJSONString.prefix(300)))
        }
        let msg = choice["message"] ?? .object([:])
        var content: [CanonicalContent] = []
        if let s = msg["content"]?.stringValue, !s.isEmpty {
            content.append(.text(s))
        } else if let parts = msg["content"]?.arrayValue {
            for p in parts {
                if let t = p["text"]?.stringValue { content.append(.text(t)) }
            }
        }
        if let refusal = msg["refusal"]?.stringValue, !refusal.isEmpty {
            content.append(.refusal(refusal))
        }
        var toolCalls: [CanonicalToolCall] = []
        for call in msg["tool_calls"]?.arrayValue ?? [] {
            toolCalls.append(CanonicalToolCall(
                id: call["id"]?.stringValue ?? "call_\(toolCalls.count)",
                name: call["function"]?["name"]?.stringValue ?? "",
                argumentsJSON: call["function"]?["arguments"]?.stringValue ?? "{}"))
        }
        var reasoning: String?
        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let r = msg[key]?.stringValue, !r.isEmpty { reasoning = r; break }
        }
        let message = CanonicalMessage(role: .assistant, content: content,
                                       toolCalls: toolCalls, reasoning: reasoning)
        return CanonicalResponse(id: json["id"]?.stringValue ?? IDGenerator.requestID(),
                                 model: json["model"]?.stringValue ?? fallbackModel,
                                 created: json["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                                 message: message,
                                 finishReason: mapFinishReason(choice["finish_reason"]?.stringValue),
                                 usage: parseUsage(json["usage"] ?? .null))
    }

    func parseUsage(_ u: JSONValue) -> CanonicalUsage {
        guard !u.isNull else { return .zero }
        let inputTokens = u["prompt_tokens"]?.intValue ?? u["input_tokens"]?.intValue ?? 0
        let outputTokens = u["completion_tokens"]?.intValue ?? u["output_tokens"]?.intValue ?? 0
        let cached = u["prompt_tokens_details"]?["cached_tokens"]?.intValue
            ?? u["cached_tokens"]?.intValue ?? 0
        let reasoning = u["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
        return CanonicalUsage(inputTokens: inputTokens, outputTokens: outputTokens,
                              cachedInputTokens: cached, reasoningTokens: reasoning)
    }

    func mapFinishReason(_ s: String?) -> CanonicalFinishReason {
        switch s {
        case "stop", "end_turn", "eos": return .stop
        case "length", "max_tokens": return .length
        case "tool_calls", "function_call", "tool_use": return .toolCalls
        case "content_filter": return .contentFilter
        case nil: return .stop
        default: return .other
        }
    }

    // MARK: - Errors

    public func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let errNode = json?["error"] ?? json
        var err = errorFromBody(errNode ?? .null, status: status, model: model)
        if let ra = headers["retry-after"].flatMap({ RateLimitSnapshot.parseDuration($0) }) {
            err.retryAfter = ra
        }
        return err
    }

    private func errorFromBody(_ node: JSONValue, status: Int, model: String) -> DerbyError {
        let message = node["message"]?.stringValue
            ?? node["detail"]?.stringValue
            ?? node.stringValue
            ?? "Provider returned HTTP \(status)"
        let code = node["code"]?.stringValue ?? node["type"]?.stringValue
        let lower = (message + " " + (code ?? "")).lowercased()

        var kind: FailureKind
        switch status {
        case 400, 422:
            if lower.contains("context length") || lower.contains("context_length")
                || lower.contains("too many tokens") || lower.contains("maximum context")
                || lower.contains("reduce the length") || lower.contains("prompt is too long") {
                kind = .contextOverflow
            } else if lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist")) {
                kind = .modelUnavailable
            } else if lower.contains("content") && (lower.contains("filter") || lower.contains("policy")) {
                kind = .contentPolicy
            } else if lower.contains("does not support") || lower.contains("unsupported") {
                kind = .capabilityMismatch
            } else {
                kind = .invalidRequest
            }
        case 401: kind = .authentication
        case 403:
            kind = lower.contains("policy") || lower.contains("safety") ? .contentPolicy : .authentication
        case 404:
            kind = lower.contains("model") || !model.isEmpty ? .modelUnavailable : .invalidRequest
        case 408: kind = .timeout
        case 409: kind = .transient
        case 413: kind = .contextOverflow
        case 429:
            kind = (lower.contains("quota") || lower.contains("billing") || lower.contains("insufficient")
                    || lower.contains("credit")) ? .quotaExhausted : .rateLimit
        case 499: kind = .clientCancelled
        case 500, 502, 503, 504, 529: kind = status == 503 || status == 529 ? .providerDown : .transient
        default:
            kind = status >= 500 ? .providerDown : .unknown
        }
        // Some gateways return 200/400 for overload conditions with a clear code.
        if lower.contains("overloaded") || lower.contains("capacity") { kind = .providerDown }

        return DerbyError(kind: kind,
                          message: SecretRedactor.redact(message),
                          providerStatus: status,
                          providerCode: code,
                          detail: nil)
    }
}
