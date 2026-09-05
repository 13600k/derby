import Foundation

/// Speaks Anthropic's Messages API. One adapter serves both credential styles:
///
/// * `anthropic` — a metered API key in the `x-api-key` header.
/// * `anthropic_subscription` — the OAuth access token issued to Claude Code,
///   read from the local CLI credential store and sent as a bearer token with
///   the `oauth-2025-04-20` beta flag. That path additionally requires the first
///   system block to identify the caller as Claude Code, which this adapter
///   injects; without it the token is rejected.
public struct AnthropicAdapter: ProviderAdapter {
    public let family: AdapterFamily
    private let oauthMode: Bool

    public init(oauth: Bool = false) {
        self.oauthMode = oauth
        self.family = oauth ? .anthropicOAuth : .anthropic
    }

    public static let anthropicVersion = "2023-06-01"
    /// Required as the first system block when using subscription OAuth.
    public static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        var auth = ResolvedAuth()
        auth.headers["anthropic-version"] = Self.anthropicVersion

        switch ctx.account.auth {
        case .cli(let source, let allowRefresh):
            let cred = try await ctx.credentials.credential(for: source, allowRefresh: allowRefresh,
                                                             home: ctx.account.credentialHomeURL)
            auth.headers["authorization"] = "Bearer \(cred.accessToken)"
            auth.headers["anthropic-beta"] = "oauth-2025-04-20"
        case .apiKey(let ref):
            auth.headers["x-api-key"] = try requireSecret(ref, ctx: ctx, label: "API key")
        case .customHeader(let name, let ref, let prefix):
            let v = try requireSecret(ref, ctx: ctx, label: "credential")
            auth.headers[name.lowercased()] = prefix.isEmpty ? v : "\(prefix)\(v)"
        case .none:
            throw DerbyError(kind: .authentication,
                             message: "\(ctx.account.name) has no credentials configured.")
        case .awsSigV4:
            throw DerbyError(kind: .invalidRequest, message: "Use the Bedrock provider type for AWS credentials.")
        }
        return auth
    }

    private var usesOAuth: Bool { oauthMode }

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        let auth = try await authenticate(ctx)
        let u = try url(ctx, path: "models", auth: auth, extraQuery: ["limit": "100"])
        let req = OutboundRequest(url: u, method: "GET", headers: headers(ctx, auth: auth),
                                  timeout: min(ctx.account.requestTimeoutSeconds, 30),
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            // Subscription tokens may not be allowed to enumerate models; fall
            // back to the known-good preset list rather than failing the test.
            if usesOAuth, resp.status == 401 || resp.status == 403 || resp.status == 404 {
                return ModelCatalog.presetModels(for: ctx.account.kind).map { DiscoveredModel(id: $0) }
            }
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: "")
        }
        let items = resp.bodyJSON?["data"]?.arrayValue ?? []
        let discovered = items.compactMap { item -> DiscoveredModel? in
            guard let id = item["id"]?.stringValue else { return nil }
            let known = ModelCatalog.metadata(for: id, kind: ctx.account.kind)
            var profile = ModelProfile(ownedBy: "anthropic")
            if let created = item["created_at"]?.stringValue {
                profile.modifiedAt = ISO8601DateFormatter().date(from: created)
            }
            return DiscoveredModel(id: id,
                                   displayName: item["display_name"]?.stringValue,
                                   capabilities: known.capabilities,
                                   profile: profile.isEmpty ? nil : profile,
                                   pricing: known.pricing)
        }
        return discovered.isEmpty
            ? ModelCatalog.presetModels(for: ctx.account.kind).map { DiscoveredModel(id: $0) }
            : discovered
    }

    // MARK: - Execute

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        let auth = try await authenticate(ctx)
        let body = try buildBody(request, model: model, ctx: ctx, stream: false)
        let u = try url(ctx, path: "messages", auth: auth)
        let req = OutboundRequest(url: u, method: "POST", headers: headers(ctx, auth: auth),
                                  body: try JSONEncoder().encode(body), timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: model)
        }
        guard let json = resp.bodyJSON else {
            throw DerbyError(kind: .transient, message: "Anthropic returned a non-JSON response.",
                             providerStatus: resp.status)
        }
        return try parseResponse(json, fallbackModel: model)
    }

    public func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let auth = try await authenticate(ctx)
        let body = try buildBody(request, model: model, ctx: ctx, stream: true)
        let u = try url(ctx, path: "messages", auth: auth)
        var h = headers(ctx, auth: auth)
        h["accept"] = "text/event-stream"
        let req = OutboundRequest(url: u, method: "POST", headers: h,
                                  body: try JSONEncoder().encode(body), timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let start = try await ctx.transport.stream(req)
        guard (200..<300).contains(start.status) else {
            throw classifyError(status: start.status, headers: start.headers,
                                body: start.errorBody ?? Data(), model: model)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var usage = CanonicalUsage.zero
                var finish = CanonicalFinishReason.stop
                /// Anthropic indexes content blocks; Derby indexes tool calls.
                var toolIndexForBlock: [Int: Int] = [:]
                var nextToolIndex = 0
                do {
                    for try await event in start.events {
                        guard let json = event.json else { continue }
                        let type = json["type"]?.stringValue ?? event.event ?? ""
                        switch type {
                        case "message_start":
                            let msg = json["message"] ?? .null
                            continuation.yield(.start(id: msg["id"]?.stringValue ?? IDGenerator.requestID(),
                                                      model: msg["model"]?.stringValue ?? model))
                            usage = parseUsage(msg["usage"] ?? .null)
                        case "content_block_start":
                            let block = json["content_block"] ?? .null
                            let blockIndex = json["index"]?.intValue ?? 0
                            if block["type"]?.stringValue == "tool_use" {
                                let idx = nextToolIndex
                                nextToolIndex += 1
                                toolIndexForBlock[blockIndex] = idx
                                continuation.yield(.toolCallStart(index: idx,
                                                                  id: block["id"]?.stringValue ?? "call_\(idx)",
                                                                  name: block["name"]?.stringValue ?? ""))
                            } else if let t = block["text"]?.stringValue, !t.isEmpty {
                                continuation.yield(.textDelta(t))
                            }
                        case "content_block_delta":
                            let blockIndex = json["index"]?.intValue ?? 0
                            let delta = json["delta"] ?? .null
                            switch delta["type"]?.stringValue {
                            case "text_delta":
                                if let t = delta["text"]?.stringValue, !t.isEmpty { continuation.yield(.textDelta(t)) }
                            case "thinking_delta":
                                if let t = delta["thinking"]?.stringValue, !t.isEmpty { continuation.yield(.reasoningDelta(t)) }
                            case "input_json_delta":
                                if let p = delta["partial_json"]?.stringValue, !p.isEmpty {
                                    continuation.yield(.toolCallArgumentsDelta(index: toolIndexForBlock[blockIndex] ?? 0, delta: p))
                                }
                            default:
                                break
                            }
                        case "message_delta":
                            if let sr = json["delta"]?["stop_reason"]?.stringValue {
                                finish = mapStopReason(sr)
                            }
                            let u = parseUsage(json["usage"] ?? .null)
                            if !u.isEmpty {
                                usage = CanonicalUsage(inputTokens: max(usage.inputTokens, u.inputTokens),
                                                       outputTokens: max(usage.outputTokens, u.outputTokens),
                                                       cachedInputTokens: max(usage.cachedInputTokens, u.cachedInputTokens),
                                                       cacheWriteTokens: max(usage.cacheWriteTokens, u.cacheWriteTokens),
                                                       reasoningTokens: usage.reasoningTokens)
                            }
                        case "message_stop":
                            break
                        case "error":
                            throw classifyError(status: 500, headers: [:],
                                                body: Data(json.compactJSONString.utf8), model: model)
                        default:
                            break
                        }
                    }
                    if !usage.isEmpty { continuation.yield(.usage(usage)) }
                    continuation.yield(.finish(finish))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Body

    func buildBody(_ r: CanonicalRequest, model: String, ctx: ProviderContext, stream: Bool) throws -> JSONValue {
        var systemBlocks: [JSONValue] = []
        // The subscription token is only accepted when the caller identifies as
        // Claude Code, and it must be the first system block.
        if usesOAuth {
            systemBlocks.append(.object(["type": .string("text"), "text": .string(Self.claudeCodeIdentity)]))
        }
        var messages: [JSONValue] = []

        for m in r.messages {
            switch m.role {
            case .system, .developer:
                let text = m.joinedText
                if !text.isEmpty {
                    systemBlocks.append(.object(["type": .string("text"), "text": .string(text)]))
                }
            case .tool:
                // Tool results are user-turn content blocks in Anthropic's shape.
                let block = JSONValue.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(m.toolCallID ?? ""),
                    "content": .string(m.joinedText),
                ])
                if var last = messages.last?.objectValue, last["role"]?.stringValue == "user",
                   var content = last["content"]?.arrayValue {
                    content.append(block)
                    last["content"] = .array(content)
                    messages[messages.count - 1] = .object(last)
                } else {
                    messages.append(.object(["role": .string("user"), "content": .array([block])]))
                }
            case .assistant:
                var blocks: [JSONValue] = []
                let text = m.joinedText
                if !text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
                for tc in m.toolCalls {
                    blocks.append(.object(["type": .string("tool_use"),
                                           "id": .string(tc.id),
                                           "name": .string(tc.name),
                                           "input": tc.argumentsValue]))
                }
                if blocks.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string("")])) }
                messages.append(.object(["role": .string("assistant"), "content": .array(blocks)]))
            case .user:
                messages.append(.object(["role": .string("user"), "content": .array(m.content.map(encodeContent))]))
            }
        }

        // Anthropic requires a non-empty message list beginning with a user turn.
        if messages.isEmpty {
            messages.append(.object(["role": .string("user"),
                                     "content": .array([.object(["type": .string("text"), "text": .string("")])])]))
        }

        // max_tokens is mandatory for this API.
        let catalogMax = ModelCatalog.metadata(for: model, kind: ctx.account.kind).capabilities.maxOutputTokens
        let maxTokens = r.maxOutputTokens ?? min(catalogMax ?? 4096, 8192)

        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "messages": .array(messages),
        ]
        if !systemBlocks.isEmpty { body["system"] = .array(systemBlocks) }
        if stream { body["stream"] = .bool(true) }
        // Newer Claude models reject sampling parameters; sending one returns a
        // deprecation error rather than being ignored.
        if let t = r.temperature, ctx.allows(.temperature) { body["temperature"] = .number(t) }
        if let p = r.topP, ctx.allows(.topP) { body["top_p"] = .number(p) }
        if !r.stop.isEmpty, ctx.allows(.stop) { body["stop_sequences"] = .array(r.stop.map { .string($0) }) }
        if let u = r.user { body["metadata"] = .object(["user_id": .string(u)]) }

        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { t in
                var o: [String: JSONValue] = ["name": .string(t.name), "input_schema": t.parameters]
                if let d = t.description { o["description"] = .string(d) }
                return .object(o)
            })
            if let choice = r.toolChoice {
                switch choice {
                case .auto:
                    var o: [String: JSONValue] = ["type": .string("auto")]
                    if r.parallelToolCalls == false { o["disable_parallel_tool_use"] = .bool(true) }
                    body["tool_choice"] = .object(o)
                case .none: body["tool_choice"] = .object(["type": .string("none")])
                case .required: body["tool_choice"] = .object(["type": .string("any")])
                case .function(let n): body["tool_choice"] = .object(["type": .string("tool"), "name": .string(n)])
                }
            }
        }

        if let reasoning = r.reasoning, reasoning.effort != nil || reasoning.maxTokens != nil {
            // Extended thinking needs a token budget strictly below max_tokens.
            let budget = reasoning.maxTokens ?? (reasoning.effort ?? .medium).thinkingBudget
            let safeBudget = max(1024, min(budget, maxTokens - 1))
            if safeBudget < maxTokens {
                body["thinking"] = .object(["type": .string("enabled"),
                                            "budget_tokens": .number(Double(safeBudget))])
                // Anthropic rejects temperature/top_p while thinking is enabled.
                body.removeValue(forKey: "temperature")
                body.removeValue(forKey: "top_p")
            }
        }

        // JSON output is expressed through a forced tool in this API; leave the
        // response format to the caller rather than silently changing semantics.
        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["anthropic"] { result = result.merging(ext) }
        return result
    }

    private func encodeContent(_ c: CanonicalContent) -> JSONValue {
        switch c {
        case .text(let t), .refusal(let t):
            return .object(["type": .string("text"), "text": .string(t)])
        case .image(let img):
            if let b64 = img.base64 {
                return .object(["type": .string("image"),
                                "source": .object(["type": .string("base64"),
                                                   "media_type": .string(img.mimeType),
                                                   "data": .string(b64)])])
            }
            return .object(["type": .string("image"),
                            "source": .object(["type": .string("url"), "url": .string(img.url ?? "")])])
        case .audio:
            // No audio input on this API; degrade to a marker rather than failing
            // the whole request, since capability filtering should have excluded it.
            return .object(["type": .string("text"), "text": .string("[audio content omitted]")])
        }
    }

    // MARK: - Parsing

    func parseResponse(_ json: JSONValue, fallbackModel: String) throws -> CanonicalResponse {
        if json["type"]?.stringValue == "error" {
            throw classifyError(status: 400, headers: [:], body: Data(json.compactJSONString.utf8), model: fallbackModel)
        }
        var content: [CanonicalContent] = []
        var toolCalls: [CanonicalToolCall] = []
        var reasoning = ""
        for block in json["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let t = block["text"]?.stringValue { content.append(.text(t)) }
            case "thinking":
                if let t = block["thinking"]?.stringValue { reasoning += t }
            case "tool_use":
                toolCalls.append(CanonicalToolCall(id: block["id"]?.stringValue ?? "call_\(toolCalls.count)",
                                                   name: block["name"]?.stringValue ?? "",
                                                   argumentsJSON: (block["input"] ?? .object([:])).compactJSONString))
            default: break
            }
        }
        let message = CanonicalMessage(role: .assistant, content: content, toolCalls: toolCalls,
                                       reasoning: reasoning.isEmpty ? nil : reasoning)
        return CanonicalResponse(id: json["id"]?.stringValue ?? IDGenerator.requestID(),
                                 model: json["model"]?.stringValue ?? fallbackModel,
                                 message: message,
                                 finishReason: mapStopReason(json["stop_reason"]?.stringValue),
                                 usage: parseUsage(json["usage"] ?? .null))
    }

    func parseUsage(_ u: JSONValue) -> CanonicalUsage {
        guard !u.isNull else { return .zero }
        return CanonicalUsage(inputTokens: u["input_tokens"]?.intValue ?? 0,
                              outputTokens: u["output_tokens"]?.intValue ?? 0,
                              cachedInputTokens: u["cache_read_input_tokens"]?.intValue ?? 0,
                              cacheWriteTokens: u["cache_creation_input_tokens"]?.intValue ?? 0)
    }

    func mapStopReason(_ s: String?) -> CanonicalFinishReason {
        switch s {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens": return .length
        case "tool_use", "pause_turn": return .toolCalls
        case "refusal": return .contentFilter
        case nil: return .stop
        default: return .other
        }
    }

    public func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let node = json?["error"] ?? json ?? .null
        let message = node["message"]?.stringValue ?? "Anthropic returned HTTP \(status)"
        let code = node["type"]?.stringValue
        let lower = (message + " " + (code ?? "")).lowercased()

        var kind: FailureKind
        switch status {
        case 400:
            if lower.contains("prompt is too long") || lower.contains("context") || lower.contains("max_tokens") && lower.contains("exceed") {
                kind = .contextOverflow
            } else if lower.contains("model") && lower.contains("not") {
                kind = .modelUnavailable
            } else {
                kind = .invalidRequest
            }
        case 401:
            kind = .authentication
        case 403:
            kind = lower.contains("permission") || lower.contains("oauth") ? .authentication : .contentPolicy
        case 404: kind = .modelUnavailable
        case 413: kind = .contextOverflow
        case 429:
            kind = lower.contains("credit") || lower.contains("quota") || lower.contains("usage limit")
                ? .quotaExhausted : .rateLimit
        case 500, 502, 504: kind = .transient
        case 503, 529: kind = .providerDown
        default: kind = status >= 500 ? .providerDown : .unknown
        }
        if code == "overloaded_error" { kind = .providerDown }

        var friendly = SecretRedactor.redact(message)
        if kind == .authentication, usesOAuth {
            friendly += " — run `claude` and sign in again, or enable managed token refresh for this account."
        }
        var err = DerbyError(kind: kind, message: friendly, providerStatus: status, providerCode: code)
        if let ra = headers["retry-after"].flatMap({ RateLimitSnapshot.parseDuration($0) }) { err.retryAfter = ra }
        return err
    }
}
