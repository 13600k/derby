import Foundation

/// Uses a ChatGPT subscription as an inference backend through the Codex
/// backend's Responses API.
///
/// Credentials come from an authenticated `codex` CLI (`~/.codex/auth.json`):
/// an OAuth access token plus the ChatGPT account id, which the backend
/// requires as its own header. The endpoint only speaks streaming SSE, so the
/// non-streaming path consumes the stream and accumulates a response.
public struct ChatGPTCodexAdapter: ProviderAdapter {
    public let family: AdapterFamily = .chatgptCodex
    public init() {}

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        guard case .cli(let source, let allowRefresh) = ctx.account.auth else {
            throw DerbyError(kind: .authentication,
                             message: "\(ctx.account.name) must be linked to the Codex CLI. Run `codex login`, then re-test the connection.")
        }
        let cred = try await ctx.credentials.credential(for: source, allowRefresh: allowRefresh,
                                                             home: ctx.account.credentialHomeURL)
        guard let accountID = cred.accountID, !accountID.isEmpty else {
            throw DerbyError(kind: .authentication,
                             message: "The Codex credentials do not contain a ChatGPT account id. Run `codex login` again.")
        }
        var auth = ResolvedAuth()
        auth.headers["authorization"] = "Bearer \(cred.accessToken)"
        auth.headers["chatgpt-account-id"] = accountID
        auth.headers["openai-beta"] = "responses=experimental"
        auth.headers["originator"] = "codex_cli_rs"
        auth.headers["session_id"] = UUID().uuidString
        return auth
    }

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        _ = try await authenticate(ctx)
        // The backend publishes no model-listing endpoint, but the Codex CLI
        // caches the real catalog locally — which is both current and exactly
        // the set this account can actually use.
        let home = ctx.account.credentialHomeURL
        let entries = CodexModelCatalog.selectableModels(home: home)
        guard !entries.isEmpty else {
            let path = CodexModelCatalog.cacheURL(home: home).path
            let prefix = home.map { "CODEX_HOME=\($0.path) " } ?? ""
            throw DerbyError(kind: .modelUnavailable,
                             message: "Derby could not read the Codex model catalog at \(path). Run `\(prefix)codex` once so the CLI downloads it, then test the connection again.")
        }
        return entries.map { entry in
            DiscoveredModel(id: entry.slug,
                            displayName: entry.displayName,
                            capabilities: Self.capabilities(for: entry))
        }
    }

    /// Capabilities are taken from what the catalog actually states. Nothing is
    /// assumed: a capability Derby invents becomes a hard failure at request
    /// time, while an omitted one only costs a routing option the user can turn
    /// back on with a checkbox.
    static func capabilities(for entry: CodexModelCatalog.Entry) -> ModelCapabilities {
        var flags: CapabilityFlags = [.text, .streaming, .tools, .parallelTools, .jsonSchema]
        if !entry.supportedEfforts.isEmpty { flags.insert(.reasoning) }
        return ModelCapabilities(flags: flags, source: .discovered)
    }

    public func capabilities(model: String, ctx: ProviderContext) -> ModelCapabilities {
        if let entry = CodexModelCatalog.entry(for: model, home: ctx.account.credentialHomeURL) {
            return Self.capabilities(for: entry)
        }
        return ModelCatalog.metadata(for: model, kind: ctx.account.kind).capabilities
    }

    public func healthCheck(_ ctx: ProviderContext) async -> ConnectionTestResult {
        do {
            let cred: CLICredential
            guard case .cli(let source, _) = ctx.account.auth else {
                return .failure(DerbyError(kind: .authentication,
                                           message: "This account is not linked to the Codex CLI."))
            }
            cred = try CLICredentialReader.read(source, home: ctx.account.credentialHomeURL)
            _ = try await authenticate(ctx)
            let models = try await listModels(ctx)
            var details = ["Credentials read from \(cred.origin).",
                           "Token \(cred.expiresInDescription)."]
            if let catalog = CodexModelCatalog.load(home: ctx.account.credentialHomeURL) {
                let age = catalog.fetchedAt.map { " (catalog fetched \(Self.relativeAge($0)))" } ?? ""
                details.append("\(models.count) model\(models.count == 1 ? "" : "s") available\(age).")
                if let flagship = models.first { details.append("Flagship: \(flagship.displayName ?? flagship.id).") }
            }
            details.append("Streaming: supported · Tools: supported")
            return ConnectionTestResult(
                ok: true,
                headline: "Linked to ChatGPT subscription",
                details: details,
                discovered: models)
        } catch let e as DerbyError {
            return .failure(e)
        } catch {
            return .failure(DerbyError(kind: .unknown, message: error.localizedDescription))
        }
    }

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        var acc = StreamAccumulator()
        for try await event in try await stream(request, model: model, ctx: ctx) {
            acc.ingest(event)
        }
        return acc.makeResponse(fallbackModel: model)
    }

    public func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let auth = try await authenticate(ctx)
        let body = buildBody(request, model: model, home: ctx.account.credentialHomeURL)
        let u = try url(ctx, path: "responses", auth: auth)
        var h = headers(ctx, auth: auth)
        h["accept"] = "text/event-stream"
        let req = OutboundRequest(url: u, method: "POST", headers: h,
                                  body: try JSONEncoder().encode(body), timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: false)
        let start = try await ctx.transport.stream(req)
        guard (200..<300).contains(start.status) else {
            throw classifyError(status: start.status, headers: start.headers,
                                body: start.errorBody ?? Data(), model: model)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var usage = CanonicalUsage.zero
                var finish = CanonicalFinishReason.stop
                var toolIndexForOutput: [Int: Int] = [:]
                var nextToolIndex = 0
                var emittedStart = false
                do {
                    for try await sse in start.events {
                        guard let json = sse.json else { continue }
                        let type = json["type"]?.stringValue ?? sse.event ?? ""
                        switch type {
                        case "response.created":
                            if !emittedStart {
                                emittedStart = true
                                continuation.yield(.start(id: json["response"]?["id"]?.stringValue ?? IDGenerator.requestID(),
                                                          model: json["response"]?["model"]?.stringValue ?? model))
                            }
                        case "response.output_text.delta":
                            if let d = json["delta"]?.stringValue, !d.isEmpty { continuation.yield(.textDelta(d)) }
                        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                            if let d = json["delta"]?.stringValue, !d.isEmpty { continuation.yield(.reasoningDelta(d)) }
                        case "response.output_item.added":
                            let item = json["item"] ?? .null
                            if item["type"]?.stringValue == "function_call" {
                                let outputIndex = json["output_index"]?.intValue ?? nextToolIndex
                                let idx = nextToolIndex
                                nextToolIndex += 1
                                toolIndexForOutput[outputIndex] = idx
                                continuation.yield(.toolCallStart(index: idx,
                                                                  id: item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "call_\(idx)",
                                                                  name: item["name"]?.stringValue ?? ""))
                            }
                        case "response.function_call_arguments.delta":
                            let outputIndex = json["output_index"]?.intValue ?? 0
                            if let d = json["delta"]?.stringValue, !d.isEmpty {
                                continuation.yield(.toolCallArgumentsDelta(index: toolIndexForOutput[outputIndex] ?? 0, delta: d))
                            }
                        case "response.completed", "response.incomplete":
                            let resp = json["response"] ?? .null
                            usage = parseUsage(resp["usage"] ?? .null)
                            if type == "response.incomplete" { finish = .length }
                            else if nextToolIndex > 0 { finish = .toolCalls }
                        case "response.failed", "error":
                            let err = json["response"]?["error"] ?? json["error"] ?? .null
                            throw DerbyError(kind: .transient,
                                             message: err["message"]?.stringValue ?? "The ChatGPT backend reported a failure.",
                                             providerCode: err["code"]?.stringValue)
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

    func buildBody(_ r: CanonicalRequest, model: String, home: URL? = nil) -> JSONValue {
        var instructions: [String] = []
        var input: [JSONValue] = []

        for m in r.messages {
            switch m.role {
            case .system, .developer:
                let t = m.joinedText
                if !t.isEmpty { instructions.append(t) }
            case .user:
                let parts: [JSONValue] = m.content.map { c in
                    switch c {
                    case .text(let t), .refusal(let t):
                        return .object(["type": .string("input_text"), "text": .string(t)])
                    case .image(let img):
                        return .object(["type": .string("input_image"), "image_url": .string(img.asDataURI)])
                    case .audio:
                        return .object(["type": .string("input_text"), "text": .string("[audio content omitted]")])
                    }
                }
                input.append(.object(["type": .string("message"), "role": .string("user"),
                                      "content": .array(parts.isEmpty ? [.object(["type": .string("input_text"), "text": .string("")])] : parts)]))
            case .assistant:
                let t = m.joinedText
                if !t.isEmpty {
                    input.append(.object(["type": .string("message"), "role": .string("assistant"),
                                          "content": .array([.object(["type": .string("output_text"), "text": .string(t)])])]))
                }
                for tc in m.toolCalls {
                    input.append(.object(["type": .string("function_call"),
                                          "call_id": .string(tc.id),
                                          "name": .string(tc.name),
                                          "arguments": .string(tc.argumentsJSON.isEmpty ? "{}" : tc.argumentsJSON)]))
                }
            case .tool:
                input.append(.object(["type": .string("function_call_output"),
                                      "call_id": .string(m.toolCallID ?? ""),
                                      "output": .string(m.joinedText)]))
            }
        }
        if input.isEmpty {
            input.append(.object(["type": .string("message"), "role": .string("user"),
                                  "content": .array([.object(["type": .string("input_text"), "text": .string("")])])]))
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "instructions": .string(instructions.isEmpty ? "You are a helpful assistant." : instructions.joined(separator: "\n\n")),
            "input": .array(input),
            "stream": .bool(true),
            "store": .bool(false),
        ]
        if let m = r.maxOutputTokens { body["max_output_tokens"] = .number(Double(m)) }
        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { t in
                var o: [String: JSONValue] = ["type": .string("function"),
                                              "name": .string(t.name),
                                              "parameters": t.parameters]
                if let d = t.description { o["description"] = .string(d) }
                o["strict"] = .bool(t.strict ?? false)
                return .object(o)
            })
            if let choice = r.toolChoice {
                switch choice {
                case .auto: body["tool_choice"] = .string("auto")
                case .none: body["tool_choice"] = .string("none")
                case .required: body["tool_choice"] = .string("required")
                case .function(let n):
                    body["tool_choice"] = .object(["type": .string("function"), "name": .string(n)])
                }
            }
            if let p = r.parallelToolCalls { body["parallel_tool_calls"] = .bool(p) }
        }
        var reasoning: [String: JSONValue] = [:]
        if let effort = r.reasoning?.effort {
            // Models differ in how far the scale goes; ask for the strongest
            // level this one actually supports rather than risking a 400.
            reasoning["effort"] = .string(CodexModelCatalog.clampEffort(effort, for: model, home: home))
        }
        if r.reasoning?.include == true { reasoning["summary"] = .string("auto") }
        if !reasoning.isEmpty { body["reasoning"] = .object(reasoning) }

        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["chatgpt"] { result = result.merging(ext) }
        return result
    }

    func parseUsage(_ u: JSONValue) -> CanonicalUsage {
        guard !u.isNull else { return .zero }
        return CanonicalUsage(inputTokens: u["input_tokens"]?.intValue ?? 0,
                              outputTokens: u["output_tokens"]?.intValue ?? 0,
                              cachedInputTokens: u["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
                              reasoningTokens: u["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)
    }

    static func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    public func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let node = json?["error"] ?? json?["detail"] ?? json ?? .null
        let message = node["message"]?.stringValue ?? "The ChatGPT backend returned HTTP \(status)"
        let code = node["code"]?.stringValue ?? node["type"]?.stringValue
        let lower = (message + " " + (code ?? "")).lowercased()

        var kind: FailureKind
        switch status {
        case 400:
            kind = lower.contains("context") || lower.contains("too long") ? .contextOverflow : .invalidRequest
        case 401, 403:
            kind = .authentication
        case 404: kind = .modelUnavailable
        case 429:
            kind = lower.contains("usage limit") || lower.contains("quota") || lower.contains("plan")
                ? .quotaExhausted : .rateLimit
        case 500, 502, 504: kind = .transient
        case 503: kind = .providerDown
        default: kind = status >= 500 ? .providerDown : .unknown
        }

        var friendly = SecretRedactor.redact(message)
        if kind == .authentication || lower.contains("token_expired") {
            kind = .authentication
            friendly = "ChatGPT session expired or was rejected. Run `codex login` in Terminal, or enable managed token refresh for this account."
        } else if kind == .quotaExhausted {
            friendly += " — your ChatGPT plan's Codex allowance is used up; Derby will route elsewhere until it resets."
        }
        var err = DerbyError(kind: kind, message: friendly, providerStatus: status, providerCode: code)
        if let ra = headers["retry-after"].flatMap({ RateLimitSnapshot.parseDuration($0) }) { err.retryAfter = ra }
        return err
    }
}
