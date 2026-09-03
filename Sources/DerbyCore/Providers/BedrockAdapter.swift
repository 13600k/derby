import Foundation

/// AWS Bedrock through the unified Converse API, signed with SigV4.
public struct BedrockAdapter: ProviderAdapter {
    public let family: AdapterFamily = .bedrock
    public init() {}

    private func creds(_ ctx: ProviderContext) throws -> (AWSSigV4.Credentials, String) {
        guard case .awsSigV4(let ak, let sk, let st, let region) = ctx.account.auth else {
            throw DerbyError(kind: .authentication,
                             message: "\(ctx.account.name) needs AWS access keys. Add them in Providers.")
        }
        let access = try requireSecret(ak, ctx: ctx, label: "AWS access key id")
        let secret = try requireSecret(sk, ctx: ctx, label: "AWS secret access key")
        let token = st.flatMap { ctx.secrets.get($0) }
        return (AWSSigV4.Credentials(accessKeyID: access, secretAccessKey: secret, sessionToken: token), region)
    }

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        _ = try creds(ctx)
        return ResolvedAuth()   // signing happens per-request, over the final body
    }

    private func runtimeURL(_ ctx: ProviderContext, region: String, model: String, streaming: Bool) throws -> URL {
        let base = ctx.account.baseURLOverride?.trimmedTrailingSlash
            ?? "https://bedrock-runtime.\(region).amazonaws.com"
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let path = streaming ? "converse-stream" : "converse"
        guard let u = URL(string: "\(base)/model/\(encoded)/\(path)") else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid Bedrock URL for model \(model)")
        }
        return u
    }

    private func signedRequest(_ ctx: ProviderContext, url: URL, body: Data,
                               service: String, region: String, accept: String) throws -> OutboundRequest {
        let (c, _) = try creds(ctx)
        var h: [String: String] = ["content-type": "application/json", "accept": accept]
        for (k, v) in ctx.account.extraHeaders { h[k.lowercased()] = v }
        let signed = AWSSigV4.sign(method: body.isEmpty ? "GET" : "POST", url: url, headers: h, body: body,
                                   region: region, service: service, credentials: c)
        return OutboundRequest(url: url, method: body.isEmpty ? "GET" : "POST", headers: signed,
                               body: body.isEmpty ? nil : body, timeout: ctx.attemptTimeout)
    }

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        let (_, region) = try creds(ctx)
        guard let u = URL(string: "https://bedrock.\(region).amazonaws.com/foundation-models") else { return [] }
        let req = try signedRequest(ctx, url: u, body: Data(), service: "bedrock", region: region, accept: "application/json")
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: "")
        }
        var out: [DiscoveredModel] = []
        for m in resp.bodyJSON?["modelSummaries"]?.arrayValue ?? [] {
            guard let id = m["modelId"]?.stringValue else { continue }
            let outputs = (m["outputModalities"]?.arrayValue ?? []).compactMap { $0.stringValue }
            guard outputs.contains("TEXT") || outputs.contains("EMBEDDING") || outputs.isEmpty else { continue }
            var caps = ModelCatalog.metadata(for: id, kind: .bedrock).capabilities
            let inputs = (m["inputModalities"]?.arrayValue ?? []).compactMap { $0.stringValue }
            if inputs.contains("IMAGE") { caps.flags.insert(.vision) }
            out.append(DiscoveredModel(id: id, displayName: m["modelName"]?.stringValue, capabilities: caps))
        }
        return out
    }

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        let (_, region) = try creds(ctx)
        let body = try JSONEncoder().encode(buildBody(request, model: model))
        let u = try runtimeURL(ctx, region: region, model: model, streaming: false)
        let req = try signedRequest(ctx, url: u, body: body, service: "bedrock", region: region, accept: "application/json")
        let resp = try await ctx.transport.send(req)
        guard (200..<300).contains(resp.status) else {
            throw classifyError(status: resp.status, headers: resp.headers, body: resp.body, model: model)
        }
        guard let json = resp.bodyJSON else {
            throw DerbyError(kind: .transient, message: "Bedrock returned a non-JSON response.", providerStatus: resp.status)
        }
        var content: [CanonicalContent] = []
        var toolCalls: [CanonicalToolCall] = []
        var reasoning = ""
        for block in json["output"]?["message"]?["content"]?.arrayValue ?? [] {
            if let t = block["text"]?.stringValue { content.append(.text(t)) }
            if let rc = block["reasoningContent"]?["reasoningText"]?["text"]?.stringValue { reasoning += rc }
            if let tu = block["toolUse"], !tu.isNull {
                toolCalls.append(CanonicalToolCall(id: tu["toolUseId"]?.stringValue ?? "call_\(toolCalls.count)",
                                                   name: tu["name"]?.stringValue ?? "",
                                                   argumentsJSON: (tu["input"] ?? .object([:])).compactJSONString))
            }
        }
        return CanonicalResponse(id: IDGenerator.requestID(), model: model,
                                 message: CanonicalMessage(role: .assistant, content: content,
                                                           toolCalls: toolCalls,
                                                           reasoning: reasoning.isEmpty ? nil : reasoning),
                                 finishReason: mapStop(json["stopReason"]?.stringValue),
                                 usage: parseUsage(json["usage"] ?? .null))
    }

    public func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        let (_, region) = try creds(ctx)
        let body = try JSONEncoder().encode(buildBody(request, model: model))
        let u = try runtimeURL(ctx, region: region, model: model, streaming: true)
        let req = try signedRequest(ctx, url: u, body: body, service: "bedrock", region: region,
                                    accept: "application/vnd.amazon.eventstream")
        // The transport's SSE parser does not apply here; Bedrock frames events
        // in its own binary protocol, so read raw bytes and decode frames.
        let start = try await ctx.transport.streamRaw(req)
        guard (200..<300).contains(start.status) else {
            throw classifyError(status: start.status, headers: start.headers,
                                body: start.errorBody ?? Data(), model: model)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = AWSEventStreamParser()
                var toolIndexForBlock: [Int: Int] = [:]
                var nextToolIndex = 0
                var usage = CanonicalUsage.zero
                var finish = CanonicalFinishReason.stop
                continuation.yield(.start(id: IDGenerator.requestID(), model: model))
                do {
                    for try await chunk in start.bytes {
                        for frame in parser.consume(chunk) {
                            guard let json = try? JSONDecoder().decode(JSONValue.self, from: frame.payload) else { continue }
                            switch frame.eventType {
                            case "contentBlockStart":
                                let idx = json["contentBlockIndex"]?.intValue ?? 0
                                if let tu = json["start"]?["toolUse"], !tu.isNull {
                                    let t = nextToolIndex
                                    nextToolIndex += 1
                                    toolIndexForBlock[idx] = t
                                    continuation.yield(.toolCallStart(index: t,
                                                                      id: tu["toolUseId"]?.stringValue ?? "call_\(t)",
                                                                      name: tu["name"]?.stringValue ?? ""))
                                }
                            case "contentBlockDelta":
                                let idx = json["contentBlockIndex"]?.intValue ?? 0
                                let delta = json["delta"] ?? .null
                                if let t = delta["text"]?.stringValue, !t.isEmpty { continuation.yield(.textDelta(t)) }
                                if let r = delta["reasoningContent"]?["text"]?.stringValue, !r.isEmpty {
                                    continuation.yield(.reasoningDelta(r))
                                }
                                if let input = delta["toolUse"]?["input"]?.stringValue, !input.isEmpty {
                                    continuation.yield(.toolCallArgumentsDelta(index: toolIndexForBlock[idx] ?? 0, delta: input))
                                }
                            case "messageStop":
                                finish = mapStop(json["stopReason"]?.stringValue)
                            case "metadata":
                                usage = parseUsage(json["usage"] ?? .null)
                            case "internalServerException", "throttlingException", "modelStreamErrorException",
                                 "validationException", "serviceUnavailableException":
                                throw DerbyError(kind: frame.eventType == "throttlingException" ? .rateLimit : .providerDown,
                                                 message: json["message"]?.stringValue ?? (frame.eventType ?? "Bedrock stream error"))
                            default:
                                break
                            }
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

    func buildBody(_ r: CanonicalRequest, model: String) -> JSONValue {
        var system: [JSONValue] = []
        var messages: [JSONValue] = []

        func appendUserBlock(_ block: JSONValue) {
            if var last = messages.last?.objectValue, last["role"]?.stringValue == "user",
               var content = last["content"]?.arrayValue {
                content.append(block)
                last["content"] = .array(content)
                messages[messages.count - 1] = .object(last)
            } else {
                messages.append(.object(["role": .string("user"), "content": .array([block])]))
            }
        }

        for m in r.messages {
            switch m.role {
            case .system, .developer:
                let t = m.joinedText
                if !t.isEmpty { system.append(.object(["text": .string(t)])) }
            case .tool:
                appendUserBlock(.object(["toolResult": .object([
                    "toolUseId": .string(m.toolCallID ?? ""),
                    "content": .array([.object(["text": .string(m.joinedText)])]),
                ])]))
            case .assistant:
                var blocks: [JSONValue] = []
                let t = m.joinedText
                if !t.isEmpty { blocks.append(.object(["text": .string(t)])) }
                for tc in m.toolCalls {
                    blocks.append(.object(["toolUse": .object(["toolUseId": .string(tc.id),
                                                               "name": .string(tc.name),
                                                               "input": tc.argumentsValue])]))
                }
                if blocks.isEmpty { blocks.append(.object(["text": .string("")])) }
                messages.append(.object(["role": .string("assistant"), "content": .array(blocks)]))
            case .user:
                for c in m.content {
                    switch c {
                    case .text(let t), .refusal(let t):
                        appendUserBlock(.object(["text": .string(t)]))
                    case .image(let img):
                        let format = img.mimeType.split(separator: "/").last.map(String.init) ?? "png"
                        appendUserBlock(.object(["image": .object([
                            "format": .string(format == "jpg" ? "jpeg" : format),
                            "source": .object(["bytes": .string(img.base64 ?? "")]),
                        ])]))
                    case .audio:
                        appendUserBlock(.object(["text": .string("[audio content omitted]")]))
                    }
                }
                if m.content.isEmpty { appendUserBlock(.object(["text": .string("")])) }
            }
        }
        if messages.isEmpty { messages.append(.object(["role": .string("user"), "content": .array([.object(["text": .string("")])])])) }

        var inference: [String: JSONValue] = [:]
        if let t = r.temperature { inference["temperature"] = .number(t) }
        if let p = r.topP { inference["topP"] = .number(p) }
        if let m = r.maxOutputTokens { inference["maxTokens"] = .number(Double(m)) }
        if !r.stop.isEmpty { inference["stopSequences"] = .array(r.stop.map { .string($0) }) }

        var body: [String: JSONValue] = ["messages": .array(messages)]
        if !system.isEmpty { body["system"] = .array(system) }
        if !inference.isEmpty { body["inferenceConfig"] = .object(inference) }

        if !r.tools.isEmpty {
            var toolConfig: [String: JSONValue] = [
                "tools": .array(r.tools.map { t in
                    var spec: [String: JSONValue] = ["name": .string(t.name),
                                                     "inputSchema": .object(["json": t.parameters])]
                    if let d = t.description { spec["description"] = .string(d) }
                    return .object(["toolSpec": .object(spec)])
                }),
            ]
            if let choice = r.toolChoice {
                switch choice {
                case .auto: toolConfig["toolChoice"] = .object(["auto": .object([:])])
                case .required: toolConfig["toolChoice"] = .object(["any": .object([:])])
                case .function(let n): toolConfig["toolChoice"] = .object(["tool": .object(["name": .string(n)])])
                case .none: break
                }
            }
            body["toolConfig"] = .object(toolConfig)
        }

        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["bedrock"] { result = result.merging(ext) }
        return result
    }

    func parseUsage(_ u: JSONValue) -> CanonicalUsage {
        guard !u.isNull else { return .zero }
        return CanonicalUsage(inputTokens: u["inputTokens"]?.intValue ?? 0,
                              outputTokens: u["outputTokens"]?.intValue ?? 0,
                              cachedInputTokens: u["cacheReadInputTokens"]?.intValue ?? 0,
                              cacheWriteTokens: u["cacheWriteInputTokens"]?.intValue ?? 0)
    }

    func mapStop(_ s: String?) -> CanonicalFinishReason {
        switch s {
        case "end_turn", "stop_sequence", nil: return .stop
        case "max_tokens": return .length
        case "tool_use": return .toolCalls
        case "content_filtered", "guardrail_intervened": return .contentFilter
        default: return .other
        }
    }

    public func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let message = json?["message"]?.stringValue ?? json?["Message"]?.stringValue
            ?? "Bedrock returned HTTP \(status)"
        let type = headers["x-amzn-errortype"]?.split(separator: ":").first.map(String.init)
        let lower = (message + " " + (type ?? "")).lowercased()

        var kind: FailureKind
        switch status {
        case 400:
            if lower.contains("too many tokens") || lower.contains("input is too long") { kind = .contextOverflow }
            else if lower.contains("validation") { kind = .invalidRequest }
            else { kind = .invalidRequest }
        case 401, 403: kind = .authentication
        case 404: kind = .modelUnavailable
        case 424: kind = .transient
        case 429: kind = lower.contains("quota") ? .quotaExhausted : .rateLimit
        case 500: kind = .transient
        case 503: kind = .providerDown
        default: kind = status >= 500 ? .providerDown : .unknown
        }
        if lower.contains("throttl") { kind = .rateLimit }
        if lower.contains("accessdenied") { kind = .authentication }
        return DerbyError(kind: kind, message: SecretRedactor.redact(message),
                          providerStatus: status, providerCode: type)
    }
}
