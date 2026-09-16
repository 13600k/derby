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
    /// How this endpoint reports its models. Declarative so the generic adapter
    /// does not branch on provider identity.
    public enum DiscoveryStyle: Sendable { case openAIModels, ollamaNative }
    public var discoveryStyle: DiscoveryStyle = .openAIModels
    /// How the server reports which models are loaded in memory.
    public enum ResidencyStyle: Sendable {
        case unreported
        /// Ollama's `/api/ps`.
        case ollamaRunning
        /// LM Studio's `/api/v1/models`, whose entries list `loaded_instances`.
        case lmStudioInstances
        /// vLLM, SGLang and llama.cpp serve what they list, loaded.
        case servedModelsAreLoaded
    }
    public var residencyStyle: ResidencyStyle = .unreported
    /// How the server reports what it is working on right now.
    public enum OccupancyStyle: Sendable {
        case unreported
        /// vLLM's Prometheus gauges: requests running and waiting, KV cache use.
        case vllmMetrics
        /// SGLang's, under its own metric names.
        case sglangMetrics
        /// llama.cpp's `/slots`, one entry per decoding slot.
        case llamaCppSlots
    }
    public var occupancyStyle: OccupancyStyle = .unreported
    /// Where the server describes the model it is serving beyond its `/models`
    /// entry. A bare listing states only an id, so without this a model the
    /// catalog has never heard of looks like an 8K, tool-less chat model.
    public enum PropsStyle: Sendable {
        case unreported
        /// llama.cpp's `/props`: slot context size, modalities, and what the
        /// chat template can render (`chat_template_caps`).
        case llamaCppProps
    }
    public var propsStyle: PropsStyle = .unreported
    /// Whether Derby may learn a model's capabilities by *asking* the server —
    /// one tiny request per feature, at discovery time only.
    ///
    /// Most self-hosted servers publish an id and nothing else, and what the
    /// build supports depends on how it was launched: a vLLM started without a
    /// tool parser and one started with it list the same model. No document
    /// distinguishes them, so the only honest source is the server's own answer.
    /// Off for metered APIs, which bill for every probe and publish their
    /// metadata anyway.
    public var probesCapabilities = false
    /// Assistant-message fields that carry earlier reasoning back.
    public var reasoningReplayFields: [String] = []
    /// Accepts `chat_template_kwargs`, the switch self-hosted servers use to
    /// turn a hybrid model's thinking on or off.
    public var supportsChatTemplateKwargs = false
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
            // /v1/models reports only an id; the native API reports context
            // length, modalities, parameter size and quantization.
            q.discoveryStyle = .ollamaNative
            q.residencyStyle = .ollamaRunning
            // Maps onto Ollama's own `think` levels.
            q.supportsReasoningEffort = true
        case .lmStudio, .llamaCpp, .localai, .sglang, .vllm:
            q.supportsStreamOptions = (kind == .vllm || kind == .sglang || kind == .lmStudio)
            q.supportsParallelToolCalls = false
            q.authStyle = .none
            q.strictSchema = (kind == .llamaCpp || kind == .localai)
            q.probesCapabilities = true
            switch kind {
            case .lmStudio: q.residencyStyle = .lmStudioInstances
            case .vllm, .sglang, .llamaCpp:
                q.residencyStyle = .servedModelsAreLoaded
                q.supportsChatTemplateKwargs = true
                q.occupancyStyle = kind == .vllm ? .vllmMetrics
                    : (kind == .sglang ? .sglangMetrics : .llamaCppSlots)
                if kind == .llamaCpp { q.propsStyle = .llamaCppProps }
            default: break
            }
        case .openAICompatible:
            // Conservative defaults: unknown servers get the smallest viable body.
            q.supportsStreamOptions = false
            q.supportsParallelToolCalls = false
            q.strictSchema = true
            // Derby cannot guess what is behind a custom URL, so it asks.
            q.probesCapabilities = true
        default:
            break
        }
        q.reasoningReplayFields = kind.reasoningReplayFields
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

        if case .ollamaNative = q.discoveryStyle {
            let native = try await OllamaDiscovery.listModels(
                baseURL: auth.baseURLOverride ?? ctx.account.baseURL,
                transport: ctx.transport,
                timeout: min(ctx.account.requestTimeoutSeconds, 30),
                allowInsecureTLS: ctx.account.allowInsecureTLS,
                headers: headers(ctx, auth: auth))
            // Complete anything the server did not state from the bundled catalog.
            return native.map { model in
                var enriched = model
                let catalog = ModelCatalog.metadata(for: model.id, kind: ctx.account.kind)
                enriched.capabilities = (model.capabilities ?? catalog.capabilities)
                    .fillingGaps(from: catalog.capabilities)
                return enriched
            }
        }

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
        var models = items.compactMap { parseListedModel($0, kind: ctx.account.kind) }
        if q.propsStyle == .llamaCppProps {
            // Router mode serves several models and describes each on request;
            // a single-model server ignores the parameter.
            let native = OllamaDiscovery.nativeBase(from: auth.baseURLOverride ?? ctx.account.baseURL)
            for index in models.indices {
                var components = URLComponents(string: native + "/props")
                if models.count > 1 { components?.queryItems = [URLQueryItem(name: "model", value: models[index].id)] }
                guard let propsURL = components?.url,
                      let response = try? await ctx.transport.send(OutboundRequest(
                        url: propsURL, method: "GET", headers: headers(ctx, auth: auth),
                        timeout: min(ctx.account.requestTimeoutSeconds, 30),
                        allowInsecureTLS: ctx.account.allowInsecureTLS)),
                      (200..<300).contains(response.status), let props = response.bodyJSON
                else { continue }
                models[index] = Self.applyingLlamaCppProps(props, to: models[index])
            }
        }

        if q.probesCapabilities {
            // Ask only about models the server already has loaded. On a host
            // that loads on demand, probing the rest would page each one into
            // memory in turn just to ask it a question.
            let loaded = try? await loadedModels(ctx)
            let probeable = models.filter { loaded?.contains($0.id) ?? true }
            if probeable.count <= Self.maxModelsToProbe {
                for index in models.indices where probeable.contains(where: { $0.id == models[index].id }) {
                    guard let probed = await probedCapabilities(model: models[index].id, ctx: ctx,
                                                                quirks: q, auth: auth) else { continue }
                    // What the server just demonstrated wins; what it was silent
                    // about is still filled in from what the listing stated, and
                    // what it refused is removed however confident the guess was.
                    var merged = probed.capabilities
                        .fillingGaps(from: models[index].capabilities ?? .unknown)
                    merged.flags.subtract(probed.refused)
                    models[index].capabilities = merged
                }
            }
        }
        return models.sorted { $0.id < $1.id }
    }

    // MARK: - Capability probing

    /// One question put to the server, and what its answer proves.
    ///
    /// Accepted means the feature is there; a 4xx means this build refuses it.
    /// Anything else — a timeout, a 500, a connection that drops — proves
    /// nothing, and is therefore recorded as nothing.
    struct CapabilityProbe: Sendable {
        var label: String
        /// Granted when the server accepts the request.
        var grants: CapabilityFlags = []
        /// Marked unsupported when the server rejects it with a 4xx.
        var denies: RequestParameters = []
        var extraBody: [String: JSONValue]
        /// Flags a refusal disproves. A server that rejects an image is stating
        /// this model has no vision, which must override a catalog that guessed
        /// otherwise from the model's name — claiming a modality the model
        /// lacks is a hard failure at request time.
        var refutes: CapabilityFlags { grants }
    }

    /// What the server demonstrated, and what it refused.
    struct ProbeResult: Sendable {
        var capabilities: ModelCapabilities
        var refused: CapabilityFlags = []
    }

    /// A 1×1 transparent PNG: the smallest thing that asks "do you take images?"
    static let probePixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static let capabilityProbes: [CapabilityProbe] = [
        CapabilityProbe(label: "tools", grants: [.tools], extraBody: [
            "tools": .array([.object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("derby_probe"),
                    "description": .string("Capability probe."),
                    "parameters": .object(["type": .string("object"),
                                           "properties": .object([:])])])])]),
            "tool_choice": .string("auto"),
        ]),
        CapabilityProbe(label: "parallel tool calls", grants: [.parallelTools],
                        denies: [.parallelToolCalls], extraBody: [
            "tools": .array([.object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("derby_probe"),
                    "description": .string("Capability probe."),
                    "parameters": .object(["type": .string("object"),
                                           "properties": .object([:])])])])]),
            "parallel_tool_calls": .bool(true),
        ]),
        CapabilityProbe(label: "structured output", grants: [.jsonMode, .jsonSchema],
                        denies: [.responseFormat], extraBody: [
            "response_format": .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string("derby_probe"),
                    "schema": .object(["type": .string("object"),
                                       "properties": .object([:])])])]),
        ]),
        CapabilityProbe(label: "vision", grants: [.vision], extraBody: [
            "messages": .array([.object([
                "role": .string("user"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("hi")]),
                    .object(["type": .string("image_url"),
                             "image_url": .object(["url": .string(OpenAIAdapter.probePixel)])]),
                ])])]),
        ]),
        CapabilityProbe(label: "temperature", denies: [.temperature],
                        extraBody: ["temperature": .number(0.5)]),
    ]

    /// Asks the server what this model can do, one feature at a time.
    ///
    /// Returns nil when the plain baseline request does not succeed: a server
    /// that cannot answer at all proves nothing about any feature, and guessing
    /// from a failure would strip capabilities the model really has.
    func probedCapabilities(model: String, ctx: ProviderContext, quirks q: OpenAIQuirks,
                            auth: ResolvedAuth) async -> ProbeResult? {
        func ask(_ extra: [String: JSONValue]) async -> (status: Int, body: JSONValue?)? {
            var body: [String: JSONValue] = [
                "model": .string(model),
                "messages": .array([.object(["role": .string("user"),
                                             "content": .string("hi")])]),
                "max_tokens": .number(1),
                "stream": .bool(false),
            ]
            for (k, v) in extra { body[k] = v }
            guard let u = try? chatURL(ctx, model: model, quirks: q, auth: auth),
                  let data = try? JSONValue.object(body).stableJSONData() else { return nil }
            let request = OutboundRequest(url: u, method: "POST", headers: headers(ctx, auth: auth),
                                          body: data, timeout: Self.probeTimeout,
                                          allowInsecureTLS: ctx.account.allowInsecureTLS)
            guard let response = try? await ctx.transport.send(request) else { return nil }
            return (response.status, response.bodyJSON)
        }

        // Baseline: does this model answer a plain request at all?
        guard let baseline = await ask([:]), (200..<300).contains(baseline.status) else { return nil }
        var caps = ModelCapabilities(flags: [.text, .streaming], source: .discovered)
        // Servers that run a reasoning parser say so in the answer itself.
        if let message = baseline.body?["choices"]?[0]?["message"],
           ["reasoning", "reasoning_content", "thinking"].contains(where: { !(message[$0]?.isNull ?? true) }) {
            caps.flags.insert(.reasoning)
        }

        var refused: CapabilityFlags = []
        for probe in Self.capabilityProbes {
            guard let answer = await ask(probe.extraBody) else { continue }
            if (200..<300).contains(answer.status) {
                caps.flags.formUnion(probe.grants)
            } else if (400..<500).contains(answer.status) {
                // Only an outright refusal denies a parameter. A 5xx or a
                // timeout says the server is unwell, not that the feature is
                // missing.
                caps.unsupportedParameters.formUnion(probe.denies)
                refused.formUnion(probe.refutes)
            }
        }
        return ProbeResult(capabilities: caps, refused: refused)
    }

    /// Probes are tiny, but a cold model can still take a while to load.
    static let probeTimeout: TimeInterval = 30
    /// Above this many listed models, probing is skipped: a proxy that lists a
    /// hundred models would otherwise be hammered, and on a server that loads
    /// on demand each probe would page a different model into memory.
    static let maxModelsToProbe = 8

    /// Folds what llama.cpp's `/props` states into a discovered model. Best
    /// effort: a field the build does not publish leaves what was known alone.
    static func applyingLlamaCppProps(_ props: JSONValue, to model: DiscoveredModel) -> DiscoveredModel {
        var caps = model.capabilities ?? .unknown
        var learnedSomething = false

        // The slot's context is what a request can actually use.
        if let window = props["default_generation_settings"]?["n_ctx"]?.intValue, window > 0 {
            caps.contextWindow = window
            learnedSomething = true
        }
        if let templateCaps = props["chat_template_caps"], templateCaps.objectValue != nil {
            learnedSomething = true
            caps.flags.formUnion([.text, .streaming])
            if templateCaps["supports_tools"]?.boolValue == true
                || templateCaps["supports_tool_calls"]?.boolValue == true {
                caps.flags.insert(.tools)
                if templateCaps["supports_parallel_tool_calls"]?.boolValue == true {
                    caps.flags.insert(.parallelTools)
                }
            }
            // llama.cpp enforces `response_format` with a grammar, whatever the model.
            caps.flags.formUnion([.jsonMode, .jsonSchema])
        }
        if let template = props["chat_template"]?.stringValue,
           ["<think>", "enable_thinking", "reasoning_content"].contains(where: template.contains) {
            caps.flags.insert(.reasoning)
            learnedSomething = true
        }
        if let modalities = props["modalities"], modalities.objectValue != nil {
            // The server's word on modalities is final; a catalog guess is not.
            learnedSomething = true
            caps.flags.subtract(.allModalities)
            if modalities["vision"]?.boolValue == true { caps.flags.insert(.vision) }
            if modalities["audio"]?.boolValue == true { caps.flags.insert(.audioInput) }
        }

        guard learnedSomething else { return model }
        caps.source = .discovered
        var enriched = model
        enriched.capabilities = caps
        return enriched
    }

    // MARK: - Loaded models

    public func loadedModels(_ ctx: ProviderContext) async throws -> Set<String>? {
        let q = quirks(ctx)
        guard q.residencyStyle != .unreported else { return nil }
        let auth = try await authenticate(ctx)
        let native = OllamaDiscovery.nativeBase(from: auth.baseURLOverride ?? ctx.account.baseURL)
        let requestURL: URL?
        switch q.residencyStyle {
        case .ollamaRunning: requestURL = URL(string: native + "/api/ps")
        case .lmStudioInstances: requestURL = URL(string: native + "/api/v1/models")
        case .servedModelsAreLoaded: requestURL = try url(ctx, path: q.listModelsPath, auth: auth)
        case .unreported: return nil
        }
        guard let requestURL else { return nil }
        let response = try await ctx.transport.send(OutboundRequest(
            url: requestURL, method: "GET", headers: headers(ctx, auth: auth),
            timeout: ctx.attemptTimeout, allowInsecureTLS: ctx.account.allowInsecureTLS))
        guard (200..<300).contains(response.status), let json = response.bodyJSON else { return nil }

        switch q.residencyStyle {
        case .ollamaRunning:
            return Set((json["models"]?.arrayValue ?? []).compactMap {
                $0["model"]?.stringValue ?? $0["name"]?.stringValue
            })
        case .lmStudioInstances:
            let items = json["models"]?.arrayValue ?? json["data"]?.arrayValue ?? json.arrayValue ?? []
            return Set(items.filter { !($0["loaded_instances"]?.arrayValue ?? []).isEmpty }
                .compactMap { $0["key"]?.stringValue ?? $0["id"]?.stringValue })
        case .servedModelsAreLoaded:
            // llama.cpp in router mode lists models it has not loaded, with a status.
            return Set((json["data"]?.arrayValue ?? []).filter { item in
                guard let status = item["status"]?["value"]?.stringValue ?? item["status"]?.stringValue else { return true }
                return status == "loaded"
            }.compactMap { $0["id"]?.stringValue })
        case .unreported:
            return nil
        }
    }

    // MARK: - Occupancy

    /// Asks the server what it is doing. Best effort throughout: a server that
    /// does not publish this, or publishes it somewhere Derby cannot reach,
    /// simply says nothing and routing falls back to Derby's own counts.
    public func occupancy(_ ctx: ProviderContext) async throws -> ServerOccupancy? {
        let q = quirks(ctx)
        guard q.occupancyStyle != .unreported else { return nil }
        let auth = try await authenticate(ctx)
        let native = OllamaDiscovery.nativeBase(from: auth.baseURLOverride ?? ctx.account.baseURL)

        switch q.occupancyStyle {
        case .vllmMetrics:
            guard let page = await statusPage("/metrics", native: native, ctx, auth: auth) else { return nil }
            let s = PrometheusText.samples(String(decoding: page.body, as: UTF8.self))
            // The v1 engine publishes kv_cache_usage_perc; earlier ones called
            // the same gauge gpu_cache_usage_perc.
            let cache = PrometheusText.peak(s, "vllm:kv_cache_usage_perc")
                ?? PrometheusText.peak(s, "vllm:gpu_cache_usage_perc")
            let occupancy = ServerOccupancy(
                running: PrometheusText.total(s, "vllm:num_requests_running").map { Int($0.rounded()) },
                queued: PrometheusText.total(s, "vllm:num_requests_waiting").map { Int($0.rounded()) },
                kvCacheUsage: cache.map(Self.asFraction))
            return occupancy.isEmpty ? nil : occupancy
        case .sglangMetrics:
            guard let page = await statusPage("/metrics", native: native, ctx, auth: auth) else { return nil }
            let s = PrometheusText.samples(String(decoding: page.body, as: UTF8.self))
            let occupancy = ServerOccupancy(
                running: PrometheusText.total(s, "sglang:num_running_reqs").map { Int($0.rounded()) },
                queued: PrometheusText.total(s, "sglang:num_queue_reqs").map { Int($0.rounded()) },
                kvCacheUsage: (PrometheusText.peak(s, "sglang:token_usage")
                               ?? PrometheusText.peak(s, "sglang:kv_cache_usage")).map(Self.asFraction))
            return occupancy.isEmpty ? nil : occupancy
        case .llamaCppSlots:
            // Two pages, either of which a server may have switched off, so
            // each is asked on its own and at the same time.
            async let slotsPage = statusPage("/slots", native: native, ctx, auth: auth)
            async let metricsPage = statusPage("/metrics", native: native, ctx, auth: auth)
            var occupancy = ServerOccupancy()
            // `/slots` is one entry per decoding slot; older builds report
            // `state` (0 idle), newer ones `is_processing`.
            if let slots = await slotsPage?.bodyJSON?.arrayValue, !slots.isEmpty {
                occupancy.running = slots.filter { slot in
                    if let processing = slot["is_processing"]?.boolValue { return processing }
                    return (slot["state"]?.intValue ?? 0) != 0
                }.count
                occupancy.totalSlots = slots.count
            }
            // `/metrics`, served only with `--metrics`, is the one place
            // llama.cpp counts the requests deferred until a slot frees.
            if let page = await metricsPage {
                let s = PrometheusText.samples(String(decoding: page.body, as: UTF8.self))
                if occupancy.running == nil {
                    occupancy.running = PrometheusText.total(s, "llamacpp:requests_processing").map { Int($0.rounded()) }
                }
                occupancy.queued = PrometheusText.total(s, "llamacpp:requests_deferred").map { Int($0.rounded()) }
            }
            return occupancy.isEmpty ? nil : occupancy
        case .unreported:
            return nil
        }
    }

    /// One GET of a server's status page, or nil when it did not answer with one.
    private func statusPage(_ path: String, native: String, _ ctx: ProviderContext,
                            auth: ResolvedAuth) async -> OutboundResponse? {
        guard let url = URL(string: native + path),
              let response = try? await ctx.transport.send(OutboundRequest(
                url: url, method: "GET", headers: headers(ctx, auth: auth),
                timeout: ctx.attemptTimeout, allowInsecureTLS: ctx.account.allowInsecureTLS)),
              (200..<300).contains(response.status) else { return nil }
        return response
    }

    /// Some builds publish a ratio, others the same thing as a percentage.
    private static func asFraction(_ value: Double) -> Double {
        value > 1.5 ? value / 100 : value
    }

    /// Every name a server might publish its context window under, most
    /// specific first. OpenAI publishes none, so each implementation invented
    /// its own: vLLM `max_model_len`, llama.cpp `meta.n_ctx`, aggregators
    /// `context_length`. Reading only some of them is why a server that states
    /// its window plainly still ended up with a guessed one.
    static let contextWindowKeys = ["context_length", "context_window", "max_context_length",
                                    "max_model_len", "max_seq_len", "max_sequence_length",
                                    "max_position_embeddings", "n_ctx"]

    /// Reads whatever an OpenAI-style `/models` entry chooses to publish.
    /// Aggregators such as OpenRouter report context length, modalities,
    /// supported parameters and pricing; bare servers report only an id, and the
    /// bundled catalog fills the rest.
    func parseListedModel(_ item: JSONValue, kind: ProviderKind) -> DiscoveredModel? {
        guard let id = item["id"]?.stringValue ?? item["name"]?.stringValue else { return nil }
        let catalog = ModelCatalog.metadata(for: id, kind: kind)

        var discovered = ModelCapabilities(flags: [], source: .discovered)
        var learnedSomething = false

        // Every server spells the context window differently and none of them
        // uses OpenAI's name for it, because OpenAI does not publish one. Read
        // all of them: vLLM says `max_model_len`, llama.cpp `meta.n_ctx`,
        // aggregators `context_length`.
        if let window = Self.contextWindowKeys.lazy
            .compactMap({ item[$0]?.intValue ?? item["meta"]?[$0]?.intValue })
            .first(where: { $0 > 0 }) {
            discovered.contextWindow = window
            learnedSomething = true
        }
        if let maxOut = item["top_provider"]?["max_completion_tokens"]?.intValue
            ?? item["max_output_tokens"]?.intValue ?? item["max_tokens"]?.intValue {
            discovered.maxOutputTokens = maxOut
            learnedSomething = true
        }
        if let dimensions = item["dimensions"]?.intValue ?? item["embedding_dimensions"]?.intValue {
            discovered.embeddingDimensions = dimensions
            discovered.flags.insert(.embeddings)
            learnedSomething = true
        }

        let inputModalities = (item["architecture"]?["input_modalities"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
        let outputModalities = (item["architecture"]?["output_modalities"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
        if !inputModalities.isEmpty || !outputModalities.isEmpty {
            learnedSomething = true
            if inputModalities.contains("text") || outputModalities.contains("text") {
                discovered.flags.formUnion([.text, .streaming])
            }
            if inputModalities.contains("image") { discovered.flags.insert(.vision) }
            if inputModalities.contains("audio") { discovered.flags.insert(.audioInput) }
            if outputModalities.contains("audio") { discovered.flags.insert(.audioOutput) }
        }

        let supported = (item["supported_parameters"]?.arrayValue ?? []).compactMap { $0.stringValue }
        if !supported.isEmpty {
            learnedSomething = true
            // An enumerated list is authoritative: anything absent is rejected.
            discovered.unsupportedParameters = RequestParameters.known
                .subtracting(RequestParameters(names: supported))
            discovered.flags.formUnion([.text, .streaming])
            if supported.contains("tools") { discovered.flags.formUnion([.tools, .parallelTools]) }
            if supported.contains("response_format") { discovered.flags.insert(.jsonMode) }
            if supported.contains("structured_outputs") { discovered.flags.insert(.jsonSchema) }
            if supported.contains("reasoning") || supported.contains("include_reasoning") {
                discovered.flags.insert(.reasoning)
            }
        }

        // Published prices are per token; Derby works per million.
        var pricing: Pricing?
        if let node = item["pricing"] {
            func perMillion(_ key: String) -> Double? {
                guard let raw = node[key]?.doubleValue ?? node[key]?.stringValue.flatMap(Double.init),
                      raw > 0 else { return nil }
                return raw * 1_000_000
            }
            let input = perMillion("prompt") ?? perMillion("input")
            let output = perMillion("completion") ?? perMillion("output")
            if input != nil || output != nil {
                pricing = Pricing(inputPerMTok: input, outputPerMTok: output,
                                  cachedInputPerMTok: perMillion("input_cache_read"))
                learnedSomething = true
            }
        }

        var profile = ModelProfile(summary: item["description"]?.stringValue,
                                   ownedBy: item["owned_by"]?.stringValue)
        if let created = item["created"]?.doubleValue, created > 0 {
            profile.modifiedAt = Date(timeIntervalSince1970: created)
        }

        let capabilities = learnedSomething
            ? discovered.fillingGaps(from: catalog.capabilities)
            : catalog.capabilities
        return DiscoveredModel(id: id,
                               displayName: item["name"]?.stringValue,
                               capabilities: capabilities,
                               profile: profile.isEmpty ? nil : profile,
                               pricing: pricing ?? catalog.pricing)
    }

    // MARK: - Execute

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        let q = quirks(ctx)
        let auth = try await authenticate(ctx)
        let body = try buildChatBody(request, model: model, quirks: q, stream: false,
                                     capabilities: ctx.modelCapabilities)
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
        let body = try buildChatBody(request, model: model, quirks: q, stream: true,
                                     capabilities: ctx.modelCapabilities)
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

    func buildChatBody(_ r: CanonicalRequest, model: String, quirks q: OpenAIQuirks, stream: Bool,
                       capabilities: ModelCapabilities? = nil) throws -> JSONValue {
        // Reasoning-era models reject sampling parameters outright — sending
        // `temperature` to one fails the request with a deprecation error rather
        // than being ignored. Omit anything the model is known not to accept;
        // when nothing is known, every parameter is sent exactly as before.
        func allows(_ parameter: RequestParameters) -> Bool {
            capabilities?.allows(parameter) ?? true
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(r.messages.map { encodeMessage($0, replayFields: q.reasoningReplayFields) }),
        ]
        // A hybrid model's thinking is a template switch on self-hosted servers,
        // so a reasoning request that does not flip it is silently ignored.
        if q.supportsChatTemplateKwargs, let effort = r.reasoning?.effort,
           let flag = LineageTraits.for(ModelLineage.parse(model)).thinkingTemplateSwitch {
            body["chat_template_kwargs"] = .object([flag: .bool(effort != .minimal)])
        }
        if stream {
            body["stream"] = .bool(true)
            if q.supportsStreamOptions {
                body["stream_options"] = .object(["include_usage": .bool(true)])
            }
        }
        if let t = r.temperature, allows(.temperature) { body["temperature"] = .number(t) }
        if let p = r.topP, allows(.topP) { body["top_p"] = .number(p) }
        if let m = r.maxOutputTokens, allows(.maxTokens) {
            body[q.prefersMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = .number(Double(m))
        }
        if !r.stop.isEmpty, allows(.stop) { body["stop"] = .array(r.stop.map { .string($0) }) }
        if q.supportsSeed, allows(.seed), let s = r.seed { body["seed"] = .number(Double(s)) }
        if q.supportsPenalties {
            if let f = r.frequencyPenalty, allows(.frequencyPenalty) { body["frequency_penalty"] = .number(f) }
            if let p = r.presencePenalty, allows(.presencePenalty) { body["presence_penalty"] = .number(p) }
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
            if q.supportsParallelToolCalls, allows(.parallelToolCalls), let p = r.parallelToolCalls {
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

        if q.supportsReasoningEffort, allows(.reasoningEffort),
           let reasoning = r.reasoning, let effort = reasoning.effort {
            // Prefer the levels this model actually publishes; fall back to the
            // four the REST API has always accepted.
            body["reasoning_effort"] = .string(
                capabilities?.clampEffort(effort) ?? effort.standardOpenAIValue)
        }

        // Escape hatch: anything the user configured for this family wins.
        var result = JSONValue.object(body)
        if let ext = r.providerExtensions["openai"] {
            result = result.merging(ext)
        }
        return result
    }

    private func encodeMessage(_ m: CanonicalMessage, replayFields: [String] = []) -> JSONValue {
        var out: [String: JSONValue] = ["role": .string(m.role == .developer ? "developer" : m.role.rawValue)]
        if let n = m.name { out["name"] = .string(n) }

        switch m.role {
        case .tool:
            out["tool_call_id"] = .string(m.toolCallID ?? "")
            out["content"] = .string(m.joinedText)
        case .assistant:
            let text = m.joinedText
            out["content"] = text.isEmpty ? .null : .string(text)
            // Present only when the handoff planner kept it: the same lineage,
            // within the window its template reads back.
            if let reasoning = m.reasoning, !reasoning.isEmpty {
                for field in replayFields { out[field] = .string(reasoning) }
            }
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
                // No id means none was assigned; the executor gives it a unique one.
                id: call["id"]?.stringValue ?? "",
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
