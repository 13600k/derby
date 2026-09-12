import Foundation

/// Speaks the Gemini `generateContent` API (API key, or an OAuth token from the
/// Gemini CLI when the account is subscription-backed).
public struct GoogleAdapter: ProviderAdapter {
    public let family: AdapterFamily = .google
    public init() {}

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        var auth = ResolvedAuth()
        switch ctx.account.auth {
        case .apiKey(let ref):
            auth.headers["x-goog-api-key"] = try requireSecret(ref, ctx: ctx, label: "API key")
        case .cli(let source, let allowRefresh):
            let cred = try await ctx.credentials.credential(for: source, allowRefresh: allowRefresh,
                                                             home: ctx.account.credentialHomeURL)
            auth.headers["authorization"] = "Bearer \(cred.accessToken)"
        case .customHeader(let name, let ref, let prefix):
            let v = try requireSecret(ref, ctx: ctx, label: "credential")
            auth.headers[name.lowercased()] = prefix.isEmpty ? v : "\(prefix)\(v)"
        case .none:
            throw DerbyError(kind: .authentication, message: "\(ctx.account.name) has no credentials configured.")
        case .awsSigV4:
            throw DerbyError(kind: .invalidRequest, message: "AWS credentials cannot be used with Gemini.")
        }
        return auth
    }

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        let auth = try await authenticate(ctx)
        let u = try url(ctx, path: "models", auth: auth, extraQuery: ["pageSize": "200"])
        let req = OutboundRequest(url: u, method: "GET", headers: headers(ctx, auth: auth),
                                  timeout: min(ctx.account.requestTimeoutSeconds, 30),
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: "")
        }
        var out: [DiscoveredModel] = []
        for m in resp.bodyJSON?["models"]?.arrayValue ?? [] {
            guard let raw = m["name"]?.stringValue else { continue }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
            let methods = (m["supportedGenerationMethods"]?.arrayValue ?? []).compactMap { $0.stringValue }
            // Skip legacy/one-off endpoints that cannot serve chat or embeddings.
            guard methods.isEmpty || methods.contains("generateContent") || methods.contains("embedContent") else { continue }
            var caps = ModelCatalog.metadata(for: id, kind: ctx.account.kind).capabilities
            if let inTok = m["inputTokenLimit"]?.intValue {
                caps.maxInputTokens = inTok
                caps.contextWindow = caps.contextWindow.map { Swift.max($0, inTok) } ?? inTok
                caps.source = .discovered
            }
            if let outTok = m["outputTokenLimit"]?.intValue { caps.maxOutputTokens = outTok }
            if methods.contains("embedContent") { caps.flags = [.embeddings] }
            let profile = ModelProfile(summary: m["description"]?.stringValue,
                                       ownedBy: "google",
                                       version: m["version"]?.stringValue)
            out.append(DiscoveredModel(id: id, displayName: m["displayName"]?.stringValue,
                                       capabilities: caps,
                                       profile: profile.isEmpty ? nil : profile,
                                       pricing: ModelCatalog.metadata(for: id, kind: ctx.account.kind).pricing))
        }
        return out
    }

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        let auth = try await authenticate(ctx)
        let body = buildBody(request, model: model, capabilities: ctx.modelCapabilities)
        let u = try url(ctx, path: "models/\(model):generateContent", auth: auth)
        let req = OutboundRequest(url: u, method: "POST", headers: headers(ctx, auth: auth),
                                  body: try JSONEncoder().encode(body), timeout: ctx.attemptTimeout,
                                  allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: model)
        }
        guard let json = resp.bodyJSON else {
            throw DerbyError(kind: .transient, message: "Gemini returned a non-JSON response.", providerStatus: resp.status)
        }
        return try parseResponse(json, fallbackModel: model)
    }

    public func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let auth = try await authenticate(ctx)
        let body = buildBody(request, model: model, capabilities: ctx.modelCapabilities)
        let u = try url(ctx, path: "models/\(model):streamGenerateContent", auth: auth, extraQuery: ["alt": "sse"])
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
                var emittedStart = false
                var usage = CanonicalUsage.zero
                var finish = CanonicalFinishReason.stop
                var toolIndex = 0
                do {
                    for try await event in start.events {
                        guard let json = event.json else { continue }
                        if let err = json["error"], !err.isNull {
                            throw classifyError(status: err["code"]?.intValue ?? 500, headers: [:],
                                                body: Data(json.compactJSONString.utf8), model: model)
                        }
                        if !emittedStart {
                            emittedStart = true
                            continuation.yield(.start(id: json["responseId"]?.stringValue ?? IDGenerator.requestID(),
                                                      model: json["modelVersion"]?.stringValue ?? model))
                        }
                        if let u = json["usageMetadata"], !u.isNull { usage = parseUsage(u) }
                        guard let candidate = json["candidates"]?[0] else { continue }
                        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
                            if let t = part["text"]?.stringValue, !t.isEmpty {
                                if part["thought"]?.boolValue == true { continuation.yield(.reasoningDelta(t)) }
                                else { continuation.yield(.textDelta(t)) }
                            }
                            let signature = part["thoughtSignature"]?.stringValue
                            if let fc = part["functionCall"], !fc.isNull {
                                let idx = toolIndex
                                toolIndex += 1
                                let id = fc["id"]?.stringValue ?? ""
                                continuation.yield(.toolCallStart(index: idx, id: id,
                                                                  name: fc["name"]?.stringValue ?? ""))
                                continuation.yield(.toolCallArgumentsDelta(index: idx,
                                                                           delta: (fc["args"] ?? .object([:])).compactJSONString))
                                if let signature, !signature.isEmpty {
                                    continuation.yield(.reasoningArtifact(ReasoningArtifact(
                                        format: .geminiThoughtSignature, payload: signature, toolCallID: id)))
                                }
                            } else if let signature, !signature.isEmpty {
                                continuation.yield(.reasoningArtifact(ReasoningArtifact(
                                    format: .geminiThoughtSignature, payload: signature)))
                            }
                        }
                        if let fr = candidate["finishReason"]?.stringValue { finish = mapFinish(fr, hasTools: toolIndex > 0) }
                    }
                    if !usage.isEmpty { continuation.yield(.usage(usage)) }
                    continuation.yield(.finish(toolIndex > 0 && finish == .stop ? .toolCalls : finish))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(_ request: CanonicalEmbeddingRequest, model: String, ctx: ProviderContext) async throws
        -> CanonicalEmbeddingResponse {
        let auth = try await authenticate(ctx)
        let requests: [JSONValue] = request.inputs.map { text in
            var o: [String: JSONValue] = [
                "model": .string("models/\(model)"),
                "content": .object(["parts": .array([.object(["text": .string(text)])])]),
            ]
            if let d = request.dimensions { o["outputDimensionality"] = .number(Double(d)) }
            return .object(o)
        }
        let u = try url(ctx, path: "models/\(model):batchEmbedContents", auth: auth)
        let req = OutboundRequest(url: u, method: "POST", headers: headers(ctx, auth: auth),
                                  body: try JSONEncoder().encode(JSONValue.object(["requests": .array(requests)])),
                                  timeout: ctx.attemptTimeout, allowInsecureTLS: ctx.account.allowInsecureTLS)
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: model)
        }
        let vectors = (resp.bodyJSON?["embeddings"]?.arrayValue ?? []).compactMap {
            $0["values"]?.arrayValue?.compactMap { $0.doubleValue }
        }
        return CanonicalEmbeddingResponse(model: model, vectors: vectors,
                                          usage: CanonicalUsage(inputTokens: request.estimatedPromptTokens))
    }

    // MARK: - Body

    func buildBody(_ r: CanonicalRequest, model: String,
                   capabilities: ModelCapabilities? = nil) -> JSONValue {
        func allows(_ parameter: RequestParameters) -> Bool {
            capabilities?.allows(parameter) ?? true
        }
        var contents: [JSONValue] = []
        var systemParts: [JSONValue] = []

        for m in r.messages {
            switch m.role {
            case .system, .developer:
                let t = m.joinedText
                if !t.isEmpty { systemParts.append(.object(["text": .string(t)])) }
            case .tool:
                // Gemini matches a response to its call by function name — the
                // call id is not a name, and sending one fails the match.
                let part = JSONValue.object([
                    "functionResponse": .object([
                        "name": .string(m.name ?? "tool"),
                        "response": .object(["result": JSONValue.parse(m.joinedText) ?? .string(m.joinedText)]),
                    ]),
                ])
                // Parallel calls are answered in one turn: Gemini rejects a
                // model turn whose call count differs from the responses after it.
                if var last = contents.last?.objectValue, last["role"]?.stringValue == "user",
                   var parts = last["parts"]?.arrayValue, !parts.isEmpty,
                   parts.allSatisfy({ $0["functionResponse"] != nil }) {
                    parts.append(part)
                    last["parts"] = .array(parts)
                    contents[contents.count - 1] = .object(last)
                } else {
                    contents.append(.object(["role": .string("user"), "parts": .array([part])]))
                }
            case .assistant:
                var parts: [JSONValue] = []
                let signatures = m.reasoningArtifacts.filter { $0.format == .geminiThoughtSignature }
                let t = m.joinedText
                if !t.isEmpty {
                    var part: [String: JSONValue] = ["text": .string(t)]
                    if let sig = signatures.first(where: { $0.toolCallID == nil }) {
                        part["thoughtSignature"] = .string(sig.payload)
                    }
                    parts.append(.object(part))
                }
                for tc in m.toolCalls {
                    var part: [String: JSONValue] = ["functionCall": .object(["name": .string(tc.name),
                                                                              "args": tc.argumentsValue])]
                    if let sig = signatures.first(where: { $0.toolCallID == tc.id }) {
                        part["thoughtSignature"] = .string(sig.payload)
                    }
                    parts.append(.object(part))
                }
                if parts.isEmpty { parts.append(.object(["text": .string("")])) }
                contents.append(.object(["role": .string("model"), "parts": .array(parts)]))
            case .user:
                let parts: [JSONValue] = m.content.map { c in
                    switch c {
                    case .text(let t), .refusal(let t):
                        return .object(["text": .string(t)])
                    case .image(let img):
                        if let b64 = img.base64 {
                            return .object(["inlineData": .object(["mimeType": .string(img.mimeType),
                                                                   "data": .string(b64)])])
                        }
                        return .object(["fileData": .object(["mimeType": .string(img.mimeType),
                                                             "fileUri": .string(img.url ?? "")])])
                    case .audio(let a):
                        return .object(["inlineData": .object(["mimeType": .string("audio/\(a.format)"),
                                                               "data": .string(a.base64)])])
                    }
                }
                contents.append(.object(["role": .string("user"),
                                         "parts": .array(parts.isEmpty ? [.object(["text": .string("")])] : parts)]))
            }
        }
        if contents.isEmpty {
            contents.append(.object(["role": .string("user"), "parts": .array([.object(["text": .string("")])])]))
        }

        var gen: [String: JSONValue] = [:]
        if let t = r.temperature, allows(.temperature) { gen["temperature"] = .number(t) }
        if let p = r.topP, allows(.topP) { gen["topP"] = .number(p) }
        if let m = r.maxOutputTokens, allows(.maxTokens) { gen["maxOutputTokens"] = .number(Double(m)) }
        if !r.stop.isEmpty, allows(.stop) { gen["stopSequences"] = .array(r.stop.map { .string($0) }) }
        if let rf = r.responseFormat {
            switch rf {
            case .text: break
            case .jsonObject: gen["responseMimeType"] = .string("application/json")
            case .jsonSchema(_, let schema, _):
                gen["responseMimeType"] = .string("application/json")
                gen["responseSchema"] = sanitizeSchema(schema)
            }
        }
        if let reasoning = r.reasoning {
            var tc: [String: JSONValue] = [:]
            if let budget = reasoning.maxTokens { tc["thinkingBudget"] = .number(Double(budget)) }
            else if let e = reasoning.effort {
                // Gemini caps the thinking budget well below the strongest
                // levels other providers now offer.
                let budget = e == .minimal ? 0 : min(e.thinkingBudget, 24_576)
                tc["thinkingBudget"] = .number(Double(budget))
            }
            if reasoning.include { tc["includeThoughts"] = .bool(true) }
            if !tc.isEmpty { gen["thinkingConfig"] = .object(tc) }
        }

        var body: [String: JSONValue] = ["contents": .array(contents)]
        if !gen.isEmpty { body["generationConfig"] = .object(gen) }
        if !systemParts.isEmpty { body["systemInstruction"] = .object(["parts": .array(systemParts)]) }

        if !r.tools.isEmpty {
            body["tools"] = .array([.object(["functionDeclarations": .array(r.tools.map { t in
                var o: [String: JSONValue] = ["name": .string(t.name)]
                if let d = t.description { o["description"] = .string(d) }
                let schema = sanitizeSchema(t.parameters)
                if let obj = schema.objectValue, !(obj["properties"]?.objectValue?.isEmpty ?? true) {
                    o["parameters"] = schema
                }
                return .object(o)
            })])])
            if let choice = r.toolChoice {
                let mode: String
                var allowed: [JSONValue] = []
                switch choice {
                case .auto: mode = "AUTO"
                case .none: mode = "NONE"
                case .required: mode = "ANY"
                case .function(let n): mode = "ANY"; allowed = [.string(n)]
                }
                var fc: [String: JSONValue] = ["mode": .string(mode)]
                if !allowed.isEmpty { fc["allowedFunctionNames"] = .array(allowed) }
                body["toolConfig"] = .object(["functionCallingConfig": .object(fc)])
            }
        }

        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["google"] { result = result.merging(ext) }
        return result
    }

    /// Gemini's schema dialect rejects several JSON Schema keywords that OpenAI
    /// clients routinely send, so strip them rather than failing the request.
    private func sanitizeSchema(_ v: JSONValue) -> JSONValue {
        let banned: Set<String> = ["additionalProperties", "$schema", "$id", "definitions", "$defs",
                                   "exclusiveMinimum", "exclusiveMaximum", "const", "examples",
                                   "default", "patternProperties", "allOf", "not", "if", "then", "else"]
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, value) in o where !banned.contains(k) {
                out[k] = sanitizeSchema(value)
            }
            return .object(out)
        case .array(let a):
            return .array(a.map { sanitizeSchema($0) })
        default:
            return v
        }
    }

    // MARK: - Parsing

    func parseResponse(_ json: JSONValue, fallbackModel: String) throws -> CanonicalResponse {
        if let err = json["error"], !err.isNull {
            throw classifyError(status: err["code"]?.intValue ?? 500, headers: [:],
                                body: Data(json.compactJSONString.utf8), model: fallbackModel)
        }
        guard let candidate = json["candidates"]?[0] else {
            // A prompt blocked by safety returns no candidates at all.
            if let reason = json["promptFeedback"]?["blockReason"]?.stringValue {
                throw DerbyError(kind: .contentPolicy, message: "Gemini blocked the prompt (\(reason)).")
            }
            throw DerbyError(kind: .transient, message: "Gemini returned no candidates.")
        }
        var content: [CanonicalContent] = []
        var toolCalls: [CanonicalToolCall] = []
        var reasoning = ""
        var artifacts: [ReasoningArtifact] = []
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            if let t = part["text"]?.stringValue {
                if part["thought"]?.boolValue == true { reasoning += t } else { content.append(.text(t)) }
            }
            let signature = part["thoughtSignature"]?.stringValue
            if let fc = part["functionCall"], !fc.isNull {
                let id = fc["id"]?.stringValue ?? ""
                toolCalls.append(CanonicalToolCall(id: id,
                                                   name: fc["name"]?.stringValue ?? "",
                                                   argumentsJSON: (fc["args"] ?? .object([:])).compactJSONString))
                if let signature, !signature.isEmpty {
                    artifacts.append(ReasoningArtifact(format: .geminiThoughtSignature, payload: signature, toolCallID: id))
                }
            } else if let signature, !signature.isEmpty {
                artifacts.append(ReasoningArtifact(format: .geminiThoughtSignature, payload: signature))
            }
        }
        let msg = CanonicalMessage(role: .assistant, content: content, toolCalls: toolCalls,
                                   reasoning: reasoning.isEmpty ? nil : reasoning,
                                   reasoningArtifacts: artifacts)
        return CanonicalResponse(id: json["responseId"]?.stringValue ?? IDGenerator.requestID(),
                                 model: json["modelVersion"]?.stringValue ?? fallbackModel,
                                 message: msg,
                                 finishReason: mapFinish(candidate["finishReason"]?.stringValue, hasTools: !toolCalls.isEmpty),
                                 usage: parseUsage(json["usageMetadata"] ?? .null))
    }

    func parseUsage(_ u: JSONValue) -> CanonicalUsage {
        guard !u.isNull else { return .zero }
        return CanonicalUsage(inputTokens: u["promptTokenCount"]?.intValue ?? 0,
                              outputTokens: (u["candidatesTokenCount"]?.intValue ?? 0) + (u["thoughtsTokenCount"]?.intValue ?? 0),
                              cachedInputTokens: u["cachedContentTokenCount"]?.intValue ?? 0,
                              reasoningTokens: u["thoughtsTokenCount"]?.intValue ?? 0)
    }

    func mapFinish(_ s: String?, hasTools: Bool) -> CanonicalFinishReason {
        switch s {
        case "STOP", nil: return hasTools ? .toolCalls : .stop
        case "MAX_TOKENS": return .length
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII": return .contentFilter
        default: return .other
        }
    }

    public func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let node = json?["error"] ?? json ?? .null
        let message = node["message"]?.stringValue ?? "Gemini returned HTTP \(status)"
        let code = node["status"]?.stringValue
        let lower = (message + " " + (code ?? "")).lowercased()
        let effectiveStatus = node["code"]?.intValue ?? status

        var kind: FailureKind
        switch effectiveStatus {
        case 400:
            if lower.contains("token") && (lower.contains("exceed") || lower.contains("maximum")) { kind = .contextOverflow }
            else if lower.contains("api key") { kind = .authentication }
            else { kind = .invalidRequest }
        case 401, 403: kind = .authentication
        case 404: kind = .modelUnavailable
        case 429:
            kind = lower.contains("quota") ? .quotaExhausted : .rateLimit
        case 499: kind = .clientCancelled
        case 500, 502, 504: kind = .transient
        case 503: kind = .providerDown
        default: kind = effectiveStatus >= 500 ? .providerDown : .unknown
        }
        if lower.contains("safety") || lower.contains("blocked") { kind = .contentPolicy }

        var err = DerbyError(kind: kind, message: SecretRedactor.redact(message),
                             providerStatus: effectiveStatus, providerCode: code)
        if let ra = headers["retry-after"].flatMap({ RateLimitSnapshot.parseDuration($0) }) { err.retryAfter = ra }
        return err
    }
}
