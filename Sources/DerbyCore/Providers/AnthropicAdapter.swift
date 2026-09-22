import Foundation

/// Speaks Anthropic's Messages API. One adapter serves both credential styles:
///
/// * `anthropic` — a metered API key in the `x-api-key` header.
/// * `anthropic_subscription` — the OAuth access token issued to Claude Code,
///   read from the local CLI credential store and sent as a bearer token
///   alongside the rest of the CLI's wire identity: the beta flags, the
///   `user-agent` and `x-app` headers, and a first system block naming Claude
///   Code, without which the token is rejected. `ClaudeCodeIdentity` owns that
///   set; this adapter applies the headers in `authenticate` and the system
///   block in `buildBody`.
public struct AnthropicAdapter: ProviderAdapter {
    public let family: AdapterFamily
    private let oauthMode: Bool

    public init(oauth: Bool = false) {
        self.oauthMode = oauth
        self.family = oauth ? .anthropicOAuth : .anthropic
    }

    public static let anthropicVersion = "2023-06-01"
    /// Required as the first system block when using subscription OAuth. One
    /// part of the identity in `ClaudeCodeIdentity`, aliased here because this is
    /// where it is injected into the body.
    public static let claudeCodeIdentity = ClaudeCodeIdentity.systemPrompt

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        var auth = ResolvedAuth()
        auth.headers["anthropic-version"] = Self.anthropicVersion

        switch ctx.account.auth {
        case .cli(let source, let allowRefresh):
            let cred = try await ctx.cliCredential(source, allowRefresh: allowRefresh)
            auth.headers["authorization"] = "Bearer \(cred.accessToken)"
            // The bearer token is only half of it: Anthropic reads the betas,
            // the user-agent and `x-app` to decide *which client* is calling.
            // See `ClaudeCodeIdentity` for what each part is doing.
            for (name, value) in ClaudeCodeIdentity.headers(version: await ClaudeCodeVersion.shared.current()) {
                auth.headers[name] = value
            }
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
                                  timeout: min(ctx.account.outOfBandTimeoutSeconds, 30),
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
                /// Thinking text and signature per block, sealed on block stop.
                var thinkingForBlock: [Int: String] = [:]
                var signatureForBlock: [Int: String] = [:]
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
                            switch block["type"]?.stringValue {
                            case "tool_use":
                                let idx = nextToolIndex
                                nextToolIndex += 1
                                toolIndexForBlock[blockIndex] = idx
                                continuation.yield(.toolCallStart(index: idx,
                                                                  id: block["id"]?.stringValue ?? "",
                                                                  name: block["name"]?.stringValue ?? ""))
                            case "thinking":
                                thinkingForBlock[blockIndex] = block["thinking"]?.stringValue ?? ""
                                if let sig = block["signature"]?.stringValue, !sig.isEmpty { signatureForBlock[blockIndex] = sig }
                            case "redacted_thinking":
                                if let data = block["data"]?.stringValue, !data.isEmpty {
                                    continuation.yield(.reasoningArtifact(
                                        ReasoningArtifact(format: .anthropicRedactedThinking, payload: data)))
                                }
                            default:
                                if let t = block["text"]?.stringValue, !t.isEmpty { continuation.yield(.textDelta(t)) }
                            }
                        case "content_block_delta":
                            let blockIndex = json["index"]?.intValue ?? 0
                            let delta = json["delta"] ?? .null
                            switch delta["type"]?.stringValue {
                            case "text_delta":
                                if let t = delta["text"]?.stringValue, !t.isEmpty { continuation.yield(.textDelta(t)) }
                            case "thinking_delta":
                                if let t = delta["thinking"]?.stringValue, !t.isEmpty {
                                    thinkingForBlock[blockIndex, default: ""] += t
                                    continuation.yield(.reasoningDelta(t))
                                }
                            case "signature_delta":
                                if let sig = delta["signature"]?.stringValue, !sig.isEmpty { signatureForBlock[blockIndex] = sig }
                            case "input_json_delta":
                                if let p = delta["partial_json"]?.stringValue, !p.isEmpty {
                                    continuation.yield(.toolCallArgumentsDelta(index: toolIndexForBlock[blockIndex] ?? 0, delta: p))
                                }
                            default:
                                break
                            }
                        case "content_block_stop":
                            let blockIndex = json["index"]?.intValue ?? 0
                            if let sig = signatureForBlock.removeValue(forKey: blockIndex) {
                                continuation.yield(.reasoningArtifact(ReasoningArtifact(
                                    format: .anthropicThinking, payload: sig,
                                    text: thinkingForBlock.removeValue(forKey: blockIndex))))
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
                // Tool results are user-turn content blocks in Anthropic's shape,
                // and may carry images a tool returned.
                let images = m.content.filter(\.isImage)
                let resultContent: JSONValue = images.isEmpty
                    ? .string(m.joinedText)
                    : .array((m.joinedText.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(m.joinedText)])])
                             + images.map(encodeContent))
                let block = JSONValue.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(m.toolCallID ?? ""),
                    "content": resultContent,
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
                // Signed thinking goes back first and unmodified, exactly as the
                // model produced it. The handoff planner leaves it here only for
                // a Claude target within the turn that produced it.
                for artifact in m.reasoningArtifacts {
                    switch artifact.format {
                    case .anthropicThinking:
                        blocks.append(.object(["type": .string("thinking"),
                                               "thinking": .string(artifact.text ?? ""),
                                               "signature": .string(artifact.payload)]))
                    case .anthropicRedactedThinking:
                        blocks.append(.object(["type": .string("redacted_thinking"), "data": .string(artifact.payload)]))
                    default:
                        break
                    }
                }
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

        // What this conversation has already said is worth not paying for
        // twice; the marks go on last so every part of the body exists.
        Self.markCacheBreakpoints(&body, request: r)

        if let reasoning = r.reasoning, reasoning.effort != nil || reasoning.maxTokens != nil {
            // Thinking, in either form, cannot be combined with forced tool use.
            let forcesTool: Bool = {
                switch r.toolChoice { case .required?, .function?: return true; default: return false }
            }()
            switch Self.thinkingMode(for: model) {
            case .adaptive:
                // Claude 4.6 and later think adaptively and take depth as effort;
                // 4.7 and later reject a token budget outright. Effort still
                // applies when a forced tool keeps thinking off.
                body["output_config"] = .object(["effort": .string(
                    Self.adaptiveEffort(reasoning.effort ?? .high, model: model, capabilities: ctx.modelCapabilities))])
                guard !forcesTool else { break }
                var thinking: [String: JSONValue] = ["type": .string("adaptive")]
                if reasoning.include { thinking["display"] = .string("summarized") }
                body["thinking"] = .object(thinking)
                body.removeValue(forKey: "temperature")
                body.removeValue(forKey: "top_p")
            case .manual:
                // A tool loop resumed without the thinking block that started it
                // cannot turn manual thinking on.
                guard !forcesTool, !Self.resumesUnsignedToolLoop(r.messages) else { break }
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
        }

        // JSON output is expressed through a forced tool in this API; leave the
        // response format to the caller rather than silently changing semantics.
        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["anthropic"] { result = result.merging(ext) }
        return result
    }

    enum ThinkingMode { case adaptive, manual }

    /// Claude 4.6 onward (and every Fable and Mythos model) uses adaptive
    /// thinking; earlier models only a manual budget. An id Derby cannot place
    /// keeps the manual form it always used.
    static func thinkingMode(for model: String) -> ThinkingMode {
        let lineage = ModelLineage.parse(model)
        guard lineage.family == "claude" else { return .manual }
        if let tier = lineage.tier, tier.contains("fable") || tier.contains("mythos") { return .adaptive }
        guard let version = lineage.numericVersion else { return .manual }
        return version >= 4.6 ? .adaptive : .manual
    }

    /// Derby's effort scale mapped onto the levels a Claude model accepts.
    static func adaptiveEffort(_ effort: ReasoningEffort, model: String, capabilities: ModelCapabilities?) -> String {
        let accepted: Set<String> = ["low", "medium", "high", "xhigh", "max"]
        if capabilities?.supportedReasoningEfforts != nil, let clamped = capabilities?.clampEffort(effort),
           accepted.contains(clamped) {
            return clamped
        }
        let lineage = ModelLineage.parse(model)
        let newest = (lineage.tier.map { $0.contains("fable") || $0.contains("mythos") } ?? false)
            || (lineage.numericVersion ?? 0) >= 4.7
        switch effort {
        case .minimal, .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return newest ? "xhigh" : "high"
        case .max, .ultra: return "max"
        }
    }

    /// The request answers tool calls from an assistant turn that carries no
    /// signed thinking — made with thinking off, or by another model.
    static func resumesUnsignedToolLoop(_ messages: [CanonicalMessage]) -> Bool {
        guard messages.last?.role == .tool,
              let assistant = messages.last(where: { $0.role == .assistant }) else { return false }
        return !assistant.reasoningArtifacts.contains {
            $0.format == .anthropicThinking || $0.format == .anthropicRedactedThinking
        }
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
        var artifacts: [ReasoningArtifact] = []
        for block in json["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let t = block["text"]?.stringValue { content.append(.text(t)) }
            case "thinking":
                if let t = block["thinking"]?.stringValue { reasoning += t }
                if let sig = block["signature"]?.stringValue, !sig.isEmpty {
                    artifacts.append(ReasoningArtifact(format: .anthropicThinking, payload: sig,
                                                       text: block["thinking"]?.stringValue))
                }
            case "redacted_thinking":
                if let data = block["data"]?.stringValue, !data.isEmpty {
                    artifacts.append(ReasoningArtifact(format: .anthropicRedactedThinking, payload: data))
                }
            case "tool_use":
                toolCalls.append(CanonicalToolCall(id: block["id"]?.stringValue ?? "",
                                                   name: block["name"]?.stringValue ?? "",
                                                   argumentsJSON: (block["input"] ?? .object([:])).compactJSONString))
            default: break
            }
        }
        let message = CanonicalMessage(role: .assistant, content: content, toolCalls: toolCalls,
                                       reasoning: reasoning.isEmpty ? nil : reasoning,
                                       reasoningArtifacts: artifacts)
        return CanonicalResponse(id: json["id"]?.stringValue ?? IDGenerator.requestID(),
                                 model: json["model"]?.stringValue ?? fallbackModel,
                                 message: message,
                                 finishReason: mapStopReason(json["stop_reason"]?.stringValue),
                                 usage: parseUsage(json["usage"] ?? .null))
    }

    /// Anthropic reports a prompt in parts: `input_tokens` counts only what was
    /// neither read from the cache nor written to it. Derby's convention is the
    /// OpenAI one — the cached counts are a *subset* of the prompt — so the
    /// parts are added back up. Without this a 27k-token cached turn reports a
    /// two-token prompt.
    func parseUsage(_ u: JSONValue) -> CanonicalUsage {
        guard !u.isNull else { return .zero }
        let fresh = u["input_tokens"]?.intValue ?? 0
        let read = u["cache_read_input_tokens"]?.intValue ?? 0
        let written = u["cache_creation_input_tokens"]?.intValue ?? 0
        return CanonicalUsage(inputTokens: fresh + read + written,
                              outputTokens: u["output_tokens"]?.intValue ?? 0,
                              cachedInputTokens: read,
                              cacheWriteTokens: written)
    }

    /// Shortest prompt worth marking. Claude's own minimum is 1024 tokens
    /// (2048 on the small models), and a mark below it is ignored, so this sits
    /// above both rather than spending a breakpoint on nothing.
    static let minimumCacheablePrompt = 2_048

    /// Marks the prefixes worth caching, so a conversation that continues
    /// re-reads only what it has added.
    ///
    /// Anthropic caches everything *before* a marked block, up to four marks in
    /// one request. Two prefixes matter: the stable one — the tools and the
    /// system prompt, which a client repeats on every turn — and the growing
    /// one, the conversation itself, where marking the end of the latest turn
    /// is what lets the next turn read all of it back instead of paying for it
    /// again. A second mark a turn earlier keeps a prefix to land on when the
    /// tail of the conversation is rewritten, as compaction rewrites it.
    ///
    /// Nothing is marked unless the conversation has an answer in it already: a
    /// one-shot question would pay for the cache write and never take the read.
    static func markCacheBreakpoints(_ body: inout [String: JSONValue], request r: CanonicalRequest) {
        guard r.messages.contains(where: { $0.role == .assistant }),
              r.estimatedPromptTokens >= minimumCacheablePrompt else { return }
        let ephemeral = JSONValue.object(["type": .string("ephemeral")])

        /// Thinking blocks cannot carry a breakpoint, and an empty block is not
        /// worth one.
        func marked(_ block: JSONValue) -> JSONValue? {
            guard var fields = block.objectValue else { return nil }
            let type = fields["type"]?.stringValue ?? ""
            guard type != "thinking", type != "redacted_thinking" else { return nil }
            fields["cache_control"] = ephemeral
            return .object(fields)
        }
        func markLastEntry(of key: String) {
            guard var array = body[key]?.arrayValue, let last = array.indices.last,
                  let block = marked(array[last]) else { return }
            array[last] = block
            body[key] = .array(array)
        }
        // Tools come first in the prompt and the system blocks next, so the mark
        // on the system prompt covers both; the one on the tools survives a
        // system prompt that changes between turns.
        markLastEntry(of: "tools")
        markLastEntry(of: "system")

        guard var messages = body["messages"]?.arrayValue, !messages.isEmpty else { return }
        // The end of the latest turn, and the end of the turn before it.
        for index in Set([messages.count - 1, messages.count - 3]).filter({ $0 >= 0 }).sorted() {
            guard var message = messages[index].objectValue,
                  var content = message["content"]?.arrayValue,
                  let last = content.indices.last,
                  let block = marked(content[last]) else { continue }
            content[last] = block
            message["content"] = .array(content)
            messages[index] = .object(message)
        }
        body["messages"] = .array(messages)
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

    /// Whether the provider is saying "you have run out", in any of the several
    /// shapes it says it — and on either status code, because the subscription
    /// wording arrives as a 400 while metered exhaustion arrives as a 429.
    static func indicatesExhaustedAllowance(_ lower: String) -> Bool {
        ["extra usage", "usage limit", "quota", "credit"].contains { lower.contains($0) }
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
            } else if Self.indicatesExhaustedAllowance(lower) {
                // Anthropic reports a spent subscription allowance as a 400 with
                // prose, not as a 429. Read literally that is a malformed
                // request, whose disposition is `returnToClient` — so the client
                // got a hard failure while a target with capacity sat unused.
                kind = .quotaExhausted
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
            kind = Self.indicatesExhaustedAllowance(lower) ? .quotaExhausted : .rateLimit
        case 500, 502, 504: kind = .transient
        case 503, 529: kind = .providerDown
        default: kind = status >= 500 ? .providerDown : .unknown
        }
        if code == "overloaded_error" { kind = .providerDown }

        var friendly = SecretRedactor.redact(message)
        if kind == .authentication, usesOAuth {
            friendly += " — run `claude` and sign in again, or enable managed token refresh for this account."
        }
        if kind == .quotaExhausted, usesOAuth {
            friendly += " — Anthropic is billing this path as a third-party app. The Claude Code (plan limits) provider runs the CLI instead, which draws on the plan itself."
        }
        var err = DerbyError(kind: kind, message: friendly, providerStatus: status, providerCode: code)
        if let ra = headers["retry-after"].flatMap({ RateLimitSnapshot.parseDuration($0) }) { err.retryAfter = ra }
        return err
    }
}
