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
        // The runtime metadata of the model that actually answered, so a client
        // that only ever asked for an alias still knows what it is talking to.
        if let m = record.runtimeModel { meta["model"] = runtimeModelJSON(m) }
        if let t = record.timeToFirstTokenSeconds { meta["ttft_ms"] = .number(Double(t.msRounded)) }
        if record.costUSD > 0 { meta["estimated_cost_usd"] = .number(record.costUSD) }
        // Never let a derived token count pass for a measured one.
        if record.usage.isEstimated { meta["usage_estimated"] = .bool(true) }
        // A shortened conversation is never reported as a normal one: the
        // client sent messages the answering model did not see.
        if let c = record.compaction { meta["compaction"] = compactionJSON(c) }
        return .object(meta)
    }

    /// What Derby removed from the conversation, and why.
    public static func compactionJSON(_ c: CompactionRecord) -> JSONValue {
        var o: [String: JSONValue] = [
            "applied": .bool(true),
            "strategy": .string(c.strategy.rawValue),
            "reason": .string(c.summary),
            "target": .string(c.targetLabel),
            "context_limit_tokens": .number(Double(c.contextLimit)),
            "original_prompt_tokens": .number(Double(c.originalTokens)),
            "compacted_prompt_tokens": .number(Double(c.compactedTokens)),
            "dropped_messages": .number(Double(c.droppedMessages)),
            "kept_messages": .number(Double(c.keptMessages)),
        ]
        if let by = c.summarizedBy { o["summarized_by"] = .string(by) }
        if let f = c.summaryFailure { o["summary_failure"] = .string(f) }
        return .object(o)
    }

    /// The same metadata, for the moment a target has been chosen but the
    /// request has not finished — which is when a streaming client wants it.
    public static func routeMetadata(requestID: String, logicalModel: String, strategy: String,
                                     target: ResolvedTarget, attemptIndex: Int,
                                     routingReason: String? = nil) -> JSONValue {
        var meta: [String: JSONValue] = [
            "request_id": .string(requestID),
            "logical_model": .string(logicalModel),
            "routing_strategy": .string(strategy),
            "provider": .string(target.providerName),
            "physical_model": .string(target.modelID),
            "model": runtimeModelJSON(RuntimeModelInfo(target: target)),
            "attempt": .string(IDGenerator.attemptID(attemptIndex + 1)),
        ]
        if let routingReason { meta["routing_reason"] = .string(routingReason) }
        return .object(meta)
    }

    /// Everything Derby knows about one physical model at this moment.
    public static func runtimeModelJSON(_ m: RuntimeModelInfo) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(m.modelID),
            "display_name": .string(m.displayName),
            "provider": .string(m.providerName),
            "provider_kind": .string(m.providerKind),
            "provider_label": .string(m.providerLabel),
            "capabilities": .array(m.capabilities.names.map { .string($0) }),
            "metadata_source": .string(m.capabilitySource.rawValue),
            "quality": .number(m.quality),
            "local": .bool(m.isLocal),
            "subscription": .bool(m.isSubscription),
        ]
        if let c = m.contextWindow { o["context_window"] = .number(Double(c)) }
        if let mo = m.maxOutputTokens { o["max_output_tokens"] = .number(Double(mo)) }
        if let p = m.pricing, p.isKnown { o["pricing"] = pricingJSON(p) }
        return .object(o)
    }

    static func pricingJSON(_ p: Pricing) -> JSONValue {
        var o: [String: JSONValue] = ["flat_rate": .bool(p.isFlatRate)]
        if let v = p.inputPerMTok { o["input_per_mtok_usd"] = .number(v) }
        if let v = p.outputPerMTok { o["output_per_mtok_usd"] = .number(v) }
        if let v = p.cachedInputPerMTok { o["cached_input_per_mtok_usd"] = .number(v) }
        if let v = p.cacheWritePerMTok { o["cache_write_per_mtok_usd"] = .number(v) }
        return .object(o)
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

        /// The first chunk. `extra` carries Derby's route metadata, so a
        /// streaming client learns which physical model it is talking to before
        /// the first token rather than after the last one.
        public mutating func roleChunkIfNeeded(extra: [String: JSONValue] = [:]) -> JSONValue? {
            guard !sentRole else { return nil }
            sentRole = true
            return chunk(delta: .object(["role": .string("assistant"), "content": .string("")]), extra: extra)
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
            tailChunk(usage: usage, record: record)
        }

        /// A final chunk carrying only Derby's metadata, for streams that ended
        /// without any usage to report. The client still learns what ran.
        public func metadataChunk(record: RequestRecord) -> JSONValue {
            tailChunk(usage: nil, record: record)
        }

        /// Announces that a different physical model has taken over. Only ever
        /// sent before the first content byte, where failover is still
        /// transparent — so the client is never told one model and streamed
        /// another.
        public func routeChunk(_ route: JSONValue) -> JSONValue {
            tailChunk(usage: nil, record: nil, extra: ["x_derby": route])
        }

        private func tailChunk(usage: CanonicalUsage?, record: RequestRecord?,
                               extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = [
                "id": .string(id),
                "object": .string("chat.completion.chunk"),
                "created": .number(Double(created)),
                "model": .string(model),
                "choices": .array([]),
            ]
            if let usage { o["usage"] = usageJSON(usage) }
            if let record { o["x_derby"] = derbyMetadata(record) }
            for (k, v) in extra { o[k] = v }
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

    /// Lists the logical models, each carrying the runtime metadata of the
    /// physical model behind it. `active_model` is decided by the same router
    /// the request path uses, so what a client reads here is what it will get
    /// on the next request — not a description of the alias.
    public static func modelsList(_ snapshot: RoutingSnapshot, router: Router = Router()) -> JSONValue {
        var items: [JSONValue] = []
        for lm in snapshot.logicalModels.values.sorted(by: { $0.name < $1.name }) {
            let usable = lm.targets.filter { $0.unavailableReason == nil }
            let summary = LogicalModelCapabilitySummary.summarize(lm)
            // A neutral probe: no capability demands of our own, so the answer
            // reflects the logical model's own policy and nothing else.
            let decision = try? router.route(
                RoutingRequest(logicalModelName: lm.name,
                               requirements: CapabilityRequirements(required: []),
                               promptTokens: 0),
                snapshot: snapshot)
            let active = decision?.plan.attempts.first?.target

            var derby: [String: JSONValue] = [
                "kind": .string("logical_model"),
                "description": .string(lm.definition.summary),
                "strategy": .string(lm.definition.policy.strategy.rawValue),
                "target_count": .number(Double(summary.targetCount)),
                // Two sets, deliberately. `capabilities` is what EVERY target
                // supports, so a client relying on it keeps full failover.
                // `available_capabilities` adds what only some support: those
                // requests still work — capability filtering routes them to the
                // targets that qualify — but with fewer alternatives behind them.
                "capabilities": .array(summary.guaranteed.names.map { .string($0) }),
                "available_capabilities": .array(summary.available.names.map { .string($0) }),
                "input_modalities": .array(summary.inputModalities.map { .string($0) }),
                "output_modalities": .array(summary.outputModalities.map { .string($0) }),
                "supports_tools": .bool(summary.guaranteed.contains(.tools)),
                "supports_vision": .bool(summary.guaranteed.contains(.vision)),
                "supports_streaming": .bool(summary.guaranteed.contains(.streaming)),
                "supports_json_schema": .bool(summary.guaranteed.contains(.jsonSchema)),
                "supports_reasoning": .bool(summary.guaranteed.contains(.reasoning)),
                "targets": .array(lm.targets.map {
                    targetJSON($0, snapshot: snapshot, activeID: active?.id)
                }),
            ]
            if let active {
                derby["active_model"] = runtimeModelJSON(RuntimeModelInfo(target: active))
            }
            // A client that caches one context length per alias must cache the
            // floor, not the active target's: a strategy that spreads traffic can
            // land on a smaller window next request. Omitted rather than guessed
            // when any usable target's window is unknown, since an unknown one
            // could be smaller than all of them.
            let windows = usable.map { $0.capabilities.contextWindow }
            if !windows.isEmpty, !windows.contains(where: { $0 == nil }),
               let floor = windows.compactMap({ $0 }).min() {
                derby["min_context_window"] = .number(Double(floor))
            }
            if let reason = decision?.explanation { derby["routing_reason"] = .string(reason) }
            if !summary.partial.isEmpty {
                // Usable, but served by a subset of the group.
                derby["partial_capabilities"] = .array(summary.partial.names.map { .string($0) })
            }
            if !summary.incompatible.isEmpty {
                // A target that cannot answer this group's request shape at all —
                // an embedding model, or one that emits images rather than text.
                derby["incompatible_targets"] = .array(summary.incompatible.map {
                    .object(["target": .string($0.targetLabel), "reason": .string($0.reason)])
                })
            }
            if let ceiling = summary.maxContextWindow {
                derby["max_context_window"] = .number(Double(ceiling))
            }
            // Parameters some target rejects. A client sending one of these can
            // have its request fail outright — reasoning-era models return a
            // deprecation error for `temperature` rather than ignoring it.
            let rejected = usable.reduce(into: RequestParameters()) {
                $0.formUnion($1.capabilities.unsupportedParameters)
            }
            if !rejected.isEmpty {
                derby["unsupported_parameters"] = .array(rejected.names.map { .string($0) })
            }
            let efforts = usable.compactMap { $0.capabilities.supportedReasoningEfforts }
            if let shared = efforts.first, efforts.count == usable.count {
                let common = efforts.dropFirst().reduce(Set(shared)) { $0.intersection(Set($1)) }
                if !common.isEmpty {
                    derby["reasoning_efforts"] = .array(shared.filter { common.contains($0) }.map { .string($0) })
                }
            }
            if let out = summary.guaranteedMaxOutputTokens {
                derby["min_max_output_tokens"] = .number(Double(out))
            }
            if let dimensions = summary.embeddingDimensions {
                derby["embedding_dimensions"] = .number(Double(dimensions))
            }

            var item: [String: JSONValue] = [
                "id": .string(lm.name),
                "object": .string("model"),
                "created": .number(Double(Int(lm.definition.createdAt.timeIntervalSince1970))),
                "owned_by": .string("derby"),
                "derby": .object(derby),
            ]
            // Hoisted out of `derby` because this is the metadata clients act on
            // when they size a conversation, and most only read the top level.
            //
            // This is the largest window *reachable* through the alias, not the
            // active target's and not the floor. Safe to advertise because an
            // oversized prompt is never silently truncated: capability filtering
            // excludes targets the conversation does not fit, so the request is
            // either routed to one that fits or refused with a clear error.
            // Stable, too — unlike the active target's window, it does not move
            // as health and strategy change under the client's feet.
            //
            // The conservative counterpart, `derby.min_context_window`, is the
            // size that still fits *every* target, i.e. with full failover intact.
            if let ceiling = summary.maxContextWindow { item["context_window"] = .number(Double(ceiling)) }
            if let out = summary.maxOutputTokens { item["max_output_tokens"] = .number(Double(out)) }
            items.append(.object(item))
        }
        return .object(["object": .string("list"), "data": .array(items)])
    }

    /// One configured target, with its runtime metadata and current health.
    public static func targetJSON(_ t: ResolvedTarget, snapshot: RoutingSnapshot,
                                  activeID: UUID? = nil) -> JSONValue {
        let h = snapshot.health(for: t.key)
        var o = runtimeModelJSON(RuntimeModelInfo(target: t)).objectValue ?? [:]
        o["rank"] = .number(Double(t.order))
        o["available"] = .bool(t.unavailableReason == nil)
        if let reason = t.unavailableReason { o["unavailable_reason"] = .string(reason) }
        o["health"] = .string(h.state.rawValue)
        o["circuit"] = .string(h.circuit.rawValue)
        o["p50_ms"] = h.p50Seconds.map { .number(Double($0.msRounded)) } ?? .null
        if let activeID { o["active"] = .bool(t.id == activeID) }
        return .object(o)
    }

}
