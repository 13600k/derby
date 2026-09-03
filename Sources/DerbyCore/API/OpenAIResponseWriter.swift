import Foundation

/// Renders canonical results back into the dialect the client asked in.
public enum OpenAIResponseWriter {

    // MARK: - Derby metadata

    /// Attached to every response as `x_derby` so a client (or the test console)
    /// can see which target actually answered without opening the app.
    public static func derbyMetadata(_ record: RequestRecord) -> JSONValue {
        var attempts: [JSONValue] = []
        for a in record.attempts {
            var o: [String: JSONValue] = [
                "attempt": .string(a.id),
                "provider": .string(a.providerName),
                "model": .string(a.modelID),
                "status": .string(a.status.rawValue),
                "duration_ms": .number(Double(a.durationSeconds.msRounded)),
            ]
            if let k = a.failureKind { o["failure"] = .string(k.rawValue) }
            if let s = a.httpStatus { o["http_status"] = .number(Double(s)) }
            if let t = a.timeToFirstTokenSeconds { o["ttft_ms"] = .number(Double(t.msRounded)) }
            attempts.append(.object(o))
        }
        var meta: [String: JSONValue] = [
            "request_id": .string(record.id),
            "logical_model": .string(record.logicalModel),
            "routing_strategy": .string(record.routingStrategy),
            "routing_reason": .string(record.routingExplanation),
            "attempts": .array(attempts),
            "retries": .number(Double(record.retryCount)),
            "failovers": .number(Double(record.failoverCount)),
            "total_ms": .number(Double(record.totalSeconds.msRounded)),
        ]
        if let p = record.finalProviderName { meta["provider"] = .string(p) }
        if let m = record.finalModelID { meta["physical_model"] = .string(m) }
        if let t = record.timeToFirstTokenSeconds { meta["ttft_ms"] = .number(Double(t.msRounded)) }
        if record.costUSD > 0 { meta["estimated_cost_usd"] = .number(record.costUSD) }
        return .object(meta)
    }

    static func usageJSON(_ u: CanonicalUsage) -> JSONValue {
        var o: [String: JSONValue] = [
            "prompt_tokens": .number(Double(u.inputTokens)),
            "completion_tokens": .number(Double(u.outputTokens)),
            "total_tokens": .number(Double(u.totalTokens)),
        ]
        if u.cachedInputTokens > 0 {
            o["prompt_tokens_details"] = .object(["cached_tokens": .number(Double(u.cachedInputTokens))])
        }
        if u.reasoningTokens > 0 {
            o["completion_tokens_details"] = .object(["reasoning_tokens": .number(Double(u.reasoningTokens))])
        }
        return .object(o)
    }

    static func toolCallsJSON(_ calls: [CanonicalToolCall]) -> JSONValue {
        .array(calls.enumerated().map { i, c in
            .object(["id": .string(c.id.isEmpty ? "call_\(i)" : c.id),
                     "type": .string("function"),
                     "index": .number(Double(i)),
                     "function": .object(["name": .string(c.name),
                                          "arguments": .string(c.argumentsJSON.isEmpty ? "{}" : c.argumentsJSON)])])
        })
    }

    // MARK: - Chat completions

    public static func chatCompletion(_ response: CanonicalResponse, record: RequestRecord) -> JSONValue {
        var message: [String: JSONValue] = ["role": .string("assistant")]
        let text = response.message.joinedText
        message["content"] = text.isEmpty ? .null : .string(text)
        if !response.message.toolCalls.isEmpty {
            message["tool_calls"] = toolCallsJSON(response.message.toolCalls)
        }
        if let r = response.message.reasoning, !r.isEmpty {
            message["reasoning_content"] = .string(r)
        }
        if case .refusal(let refusal)? = response.message.content.first(where: {
            if case .refusal = $0 { return true } else { return false }
        }) {
            message["refusal"] = .string(refusal)
        }

        return .object([
            "id": .string("chatcmpl-\(record.id.replacingOccurrences(of: "req_", with: ""))"),
            "object": .string("chat.completion"),
            "created": .number(Double(Int(response.created.timeIntervalSince1970))),
            "model": .string(response.model),
            "system_fingerprint": .string("derby"),
            "choices": .array([.object([
                "index": .number(0),
                "message": .object(message),
                "logprobs": .null,
                "finish_reason": .string(response.finishReason.rawValue),
            ])]),
            "usage": usageJSON(response.usage),
            "x_derby": derbyMetadata(record),
        ])
    }

    /// Streaming chunk emitter for `chat.completions`.
    public struct ChatChunkEmitter {
        public let id: String
        public let created: Int
        public var model: String
        private var sentRole = false

        public init(requestID: String, model: String) {
            self.id = "chatcmpl-\(requestID.replacingOccurrences(of: "req_", with: ""))"
            self.created = Int(Date().timeIntervalSince1970)
            self.model = model
        }

        private func chunk(delta: JSONValue, finish: JSONValue = .null, extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(id),
                "object": .string("chat.completion.chunk"),
                "created": .number(Double(created)),
                "model": .string(model),
                "system_fingerprint": .string("derby"),
                "choices": .array([.object(["index": .number(0), "delta": delta, "finish_reason": finish])]),
            ]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }

        public mutating func roleChunkIfNeeded() -> JSONValue? {
            guard !sentRole else { return nil }
            sentRole = true
            return chunk(delta: .object(["role": .string("assistant"), "content": .string("")]))
        }

        public func textChunk(_ text: String) -> JSONValue {
            chunk(delta: .object(["content": .string(text)]))
        }
        public func reasoningChunk(_ text: String) -> JSONValue {
            chunk(delta: .object(["reasoning_content": .string(text)]))
        }
        public func toolCallStartChunk(index: Int, id: String, name: String) -> JSONValue {
            chunk(delta: .object(["tool_calls": .array([.object([
                "index": .number(Double(index)),
                "id": .string(id.isEmpty ? "call_\(index)" : id),
                "type": .string("function"),
                "function": .object(["name": .string(name), "arguments": .string("")]),
            ])])]))
        }
        public func toolCallArgsChunk(index: Int, delta: String) -> JSONValue {
            chunk(delta: .object(["tool_calls": .array([.object([
                "index": .number(Double(index)),
                "function": .object(["arguments": .string(delta)]),
            ])])]))
        }
        public func finishChunk(_ reason: CanonicalFinishReason) -> JSONValue {
            chunk(delta: .object([:]), finish: .string(reason.rawValue))
        }
        public func usageChunk(_ usage: CanonicalUsage, record: RequestRecord?) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(id),
                "object": .string("chat.completion.chunk"),
                "created": .number(Double(created)),
                "model": .string(model),
                "choices": .array([]),
                "usage": usageJSON(usage),
            ]
            if let record { o["x_derby"] = derbyMetadata(record) }
            return .object(o)
        }
    }

    // MARK: - Responses API

    public static func responsesObject(_ response: CanonicalResponse, record: RequestRecord,
                                       status: String = "completed") -> JSONValue {
        var output: [JSONValue] = []
        let text = response.message.joinedText
        if !text.isEmpty {
            output.append(.object([
                "type": .string("message"),
                "id": .string("msg_\(IDGenerator.short())"),
                "role": .string("assistant"),
                "status": .string("completed"),
                "content": .array([.object(["type": .string("output_text"),
                                            "text": .string(text),
                                            "annotations": .array([])])]),
            ]))
        }
        for c in response.message.toolCalls {
            output.append(.object([
                "type": .string("function_call"),
                "id": .string("fc_\(IDGenerator.short())"),
                "call_id": .string(c.id),
                "name": .string(c.name),
                "arguments": .string(c.argumentsJSON.isEmpty ? "{}" : c.argumentsJSON),
                "status": .string("completed"),
            ]))
        }
        return .object([
            "id": .string("resp_\(record.id.replacingOccurrences(of: "req_", with: ""))"),
            "object": .string("response"),
            "created_at": .number(Double(Int(response.created.timeIntervalSince1970))),
            "status": .string(status),
            "model": .string(response.model),
            "output": .array(output),
            "output_text": .string(text),
            "parallel_tool_calls": .bool(true),
            "usage": .object([
                "input_tokens": .number(Double(response.usage.inputTokens)),
                "output_tokens": .number(Double(response.usage.outputTokens)),
                "total_tokens": .number(Double(response.usage.totalTokens)),
                "output_tokens_details": .object(["reasoning_tokens": .number(Double(response.usage.reasoningTokens))]),
            ]),
            "x_derby": derbyMetadata(record),
        ])
    }

    // MARK: - Errors

    public static func errorObject(_ error: DerbyError, requestID: String, record: RequestRecord? = nil) -> JSONValue {
        var err: [String: JSONValue] = [
            "message": .string(error.message),
            "type": .string(error.openAIErrorType),
            "param": .null,
            "code": .string(error.providerCode ?? error.kind.rawValue.lowercased()),
        ]
        err["derby_failure_kind"] = .string(error.kind.rawValue)
        if let d = error.detail, !d.isEmpty { err["derby_detail"] = .string(d) }
        var o: [String: JSONValue] = ["error": .object(err), "request_id": .string(requestID)]
        if let record { o["x_derby"] = derbyMetadata(record) }
        return .object(o)
    }

    // MARK: - Models list

    public static func modelsList(_ snapshot: RoutingSnapshot) -> JSONValue {
        var items: [JSONValue] = []
        for lm in snapshot.logicalModels.values.sorted(by: { $0.name < $1.name }) {
            let usable = lm.targets.filter { $0.unavailableReason == nil }
            items.append(.object([
                "id": .string(lm.name),
                "object": .string("model"),
                "created": .number(Double(Int(lm.definition.createdAt.timeIntervalSince1970))),
                "owned_by": .string("derby"),
                "derby": .object([
                    "kind": .string("logical_model"),
                    "description": .string(lm.definition.summary),
                    "strategy": .string(lm.definition.policy.strategy.rawValue),
                    "targets": .number(Double(usable.count)),
                    "capabilities": .array(unionCapabilities(usable).names.map { .string($0) }),
                ]),
            ]))
        }
        return .object(["object": .string("list"), "data": .array(items)])
    }

    private static func unionCapabilities(_ targets: [ResolvedTarget]) -> CapabilityFlags {
        targets.reduce(into: CapabilityFlags()) { $0.formUnion($1.capabilities.flags) }
    }
}
