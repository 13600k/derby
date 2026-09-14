import Foundation

/// A live model-metadata catalog, cached on disk.
///
/// Provider `/models` endpoints almost never report a context window: OpenAI and
/// Anthropic return little more than an id. Derby's bundled catalog fills that
/// gap, but it is written by hand and therefore always trails the models people
/// actually run — a frontier model released after it was written falls through
/// to "unknown", losing not just its window but its tool and vision support.
///
/// So the bundled table is the *fallback*, not the source of truth. The source is
/// `models.dev`, a community-maintained index carrying exactly the fields routing
/// needs. It is fetched, cached to disk, and re-read on launch, so Derby works
/// offline and never blocks on the network.
public final class RemoteModelCatalog: @unchecked Sendable {
    public static let shared = RemoteModelCatalog()

    public static let defaultURL = URL(string: "https://models.dev/api.json")!
    /// Refetch at most this often; the index moves on the order of days.
    public static let refreshInterval: TimeInterval = 12 * 3600

    public struct Entry: Sendable, Hashable {
        public var id: String
        public var name: String?
        public var family: String?
        public var summary: String?
        public var contextWindow: Int?
        public var maxOutputTokens: Int?
        public var inputModalities: [String]
        public var outputModalities: [String]
        public var toolCall: Bool
        public var reasoning: Bool
        public var structuredOutput: Bool
        /// False when the model rejects `temperature` outright — common for
        /// reasoning-era models, and the cause of "temperature is deprecated".
        public var temperature: Bool
        public var reasoningEfforts: [String]
        public var pricing: Pricing?
        public var releaseDate: String?
        public var openWeights: Bool

        /// Translated into Derby's capability vocabulary. Modalities come from
        /// what the index states and are never inferred.
        public var capabilities: ModelCapabilities {
            var flags: CapabilityFlags = []
            if outputModalities.contains("text") || outputModalities.isEmpty { flags.insert(.text) }
            if outputModalities.contains("image") { flags.insert(.imageOutput) }
            if outputModalities.contains("audio") { flags.insert(.audioOutput) }
            if outputModalities.contains("embedding") { flags.insert(.embeddings) }
            if inputModalities.contains("image") { flags.insert(.vision) }
            if inputModalities.contains("audio") { flags.insert(.audioInput) }
            if flags.contains(.text) { flags.insert(.streaming) }
            if toolCall { flags.formUnion([.tools, .parallelTools]) }
            if structuredOutput { flags.formUnion([.jsonMode, .jsonSchema]) }
            if reasoning { flags.insert(.reasoning) }

            // Only ever a deny-list: a parameter is excluded when the catalog
            // actually says so, never merely because it went unmentioned.
            var unsupported = RequestParameters()
            if !temperature { unsupported.formUnion([.temperature, .topP, .topK]) }
            if !toolCall { unsupported.insert(.parallelToolCalls) }
            if !reasoning { unsupported.insert(.reasoningEffort) }

            return ModelCapabilities(flags: flags,
                                     contextWindow: contextWindow,
                                     maxOutputTokens: maxOutputTokens,
                                     unsupportedParameters: unsupported,
                                     supportedReasoningEfforts: reasoningEfforts.isEmpty ? nil : reasoningEfforts,
                                     source: .discovered)
        }

        public var profile: ModelProfile {
            ModelProfile(family: family,
                         summary: summary,
                         ownedBy: openWeights ? "open weights" : nil,
                         version: releaseDate)
        }
    }

    struct Index: Sendable {
        var byProvider: [String: [String: Entry]] = [:]
        /// Every model id seen anywhere, for a cross-provider fallback lookup.
        var anyProvider: [String: Entry] = [:]
        var fetchedAt: Date?
        var modelCount: Int { anyProvider.count }
    }

    private let lock = NSLock()
    private var index = Index()
    private var loadedFromDisk = false
    private var refreshing = false

    public var cacheURL: URL { AppPaths.supportDirectory.appendingPathComponent("model-catalog.json") }

    private init() {}

    // MARK: - Loading

    /// Reads the disk cache once, lazily. Cheap and synchronous, so the routing
    /// path can consult the catalog without awaiting anything.
    private func ensureLoaded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        guard var parsed = Self.parse(data) else { return }
        parsed.fetchedAt = (try? FileManager.default
            .attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        index = parsed
    }

    public var status: (modelCount: Int, fetchedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return (index.modelCount, index.fetchedAt)
    }

    public var isStale: Bool {
        let current = status
        guard let at = current.fetchedAt, current.modelCount > 0 else { return true }
        return Date().timeIntervalSince(at) > Self.refreshInterval
    }

    // MARK: - Lookup

    /// models.dev provider ids for a Derby provider kind. Subscription-backed
    /// accounts resolve to the vendor behind them.
    static func providerIDs(for kind: ProviderKind) -> [String] {
        switch kind {
        case .openai, .chatgptSubscription: return ["openai"]
        case .azureOpenAI: return ["azure", "openai"]
        case .anthropic, .anthropicSubscription, .claudeCodeCLI: return ["anthropic"]
        case .google, .geminiSubscription: return ["google"]
        case .bedrock: return ["amazon-bedrock", "anthropic"]
        case .openrouter: return ["openrouter"]
        case .together: return ["togetherai"]
        case .fireworks: return ["fireworks-ai"]
        case .groq: return ["groq"]
        case .mistral: return ["mistral"]
        case .deepseek: return ["deepseek"]
        case .xai: return ["xai"]
        case .qwen, .qwenSubscription: return ["alibaba"]
        case .ollama, .lmStudio, .llamaCpp, .vllm, .sglang, .localai:
            return ["ollama-cloud", "lmstudio", "llama"]
        case .openAICompatible: return []
        }
    }

    /// Finds an entry, preferring the vendor this account belongs to and falling
    /// back to any provider publishing the same model id.
    public func lookup(_ modelID: String, kind: ProviderKind) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard !index.anyProvider.isEmpty else { return nil }

        let candidates = Self.candidateIDs(for: modelID)
        for provider in Self.providerIDs(for: kind) {
            guard let models = index.byProvider[provider] else { continue }
            for candidate in candidates where models[candidate] != nil {
                return models[candidate]
            }
        }
        // A model served through an aggregator, or a local copy of a hosted one,
        // still matches on id alone.
        for candidate in candidates where index.anyProvider[candidate] != nil {
            return index.anyProvider[candidate]
        }
        return nil
    }

    /// The newest id this provider offers whose name contains `needle`, by
    /// release date. Used to resolve a tier alias such as "opus" to the model a
    /// CLI would actually run, which changes whenever the vendor ships one.
    public func newestID(containing needle: String, kind: ProviderKind) -> String? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let needle = needle.lowercased()
        for provider in Self.providerIDs(for: kind) {
            guard let models = index.byProvider[provider] else { continue }
            let matches = models.values.filter { $0.id.lowercased().contains(needle) }
            // An entry with no stated release date cannot be called the newest.
            if let newest = matches.filter({ $0.releaseDate != nil })
                .max(by: { ($0.releaseDate ?? "", $0.id) < ($1.releaseDate ?? "", $1.id) }) {
                return newest.id
            }
        }
        return nil
    }

    /// Progressively looser forms of a model id, most specific first.
    static func candidateIDs(for modelID: String) -> [String] {
        var out: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            if !trimmed.isEmpty && !out.contains(trimmed) { out.append(trimmed) }
        }
        add(modelID)
        // "vendor/model", as served by aggregators and local runners.
        if let slash = modelID.lastIndex(of: "/") { add(String(modelID[modelID.index(after: slash)...])) }
        // Ollama tags: "qwen3.5:9b" -> "qwen3.5".
        if let colon = modelID.firstIndex(of: ":") { add(String(modelID[modelID.startIndex..<colon])) }
        // Dated snapshots: "claude-sonnet-4-5-20250929" -> "claude-sonnet-4-5".
        let parts = modelID.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            add(parts.dropLast().joined(separator: "-"))
        }
        return out
    }

    // MARK: - Refresh

    /// Downloads the index and rewrites the cache. Failures leave the previous
    /// cache in place, so a refresh can never make Derby know less than it did.
    @discardableResult
    public func refresh(url: URL = RemoteModelCatalog.defaultURL,
                        transport: (any HTTPTransport)? = nil,
                        timeout: TimeInterval = 45) async -> Result<Int, DerbyError> {
        let http = transport ?? URLSessionTransport.shared
        do {
            let response = try await http.send(OutboundRequest(url: url, method: "GET", timeout: timeout))
            guard (200..<300).contains(response.status) else {
                return .failure(DerbyError(kind: .transient,
                                           message: "Model catalog request failed (HTTP \(response.status)).",
                                           providerStatus: response.status))
            }
            guard var parsed = Self.parse(response.body) else {
                return .failure(DerbyError(kind: .transient,
                                           message: "The model catalog was not in the expected format."))
            }
            parsed.fetchedAt = Date()
            lock.lock()
            index = parsed
            loadedFromDisk = true
            let count = index.modelCount
            lock.unlock()
            try? response.body.write(to: cacheURL, options: .atomic)
            return .success(count)
        } catch let error as DerbyError {
            return .failure(error)
        } catch {
            return .failure(DerbyError(kind: .transient, message: error.localizedDescription))
        }
    }

    /// Refreshes in the background when the cache is missing or old.
    public func refreshIfStale() {
        lock.lock()
        let alreadyRunning = refreshing
        if !alreadyRunning { refreshing = true }
        lock.unlock()
        guard !alreadyRunning, isStale else {
            if !alreadyRunning { lock.lock(); refreshing = false; lock.unlock() }
            return
        }
        Task { [weak self] in
            _ = await self?.refresh()
            guard let self else { return }
            self.lock.lock(); self.refreshing = false; self.lock.unlock()
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Index? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var index = Index()
        for (providerID, rawProvider) in root {
            guard let provider = rawProvider as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            var parsed: [String: Entry] = [:]
            for (modelID, rawModel) in models {
                guard let model = rawModel as? [String: Any] else { continue }
                let entry = parseModel(id: modelID, model)
                let key = entry.id.lowercased()
                parsed[key] = entry
                // First writer wins, so a vendor's own entry is not displaced by
                // an aggregator's copy of it.
                if index.anyProvider[key] == nil { index.anyProvider[key] = entry }
            }
            if !parsed.isEmpty { index.byProvider[providerID.lowercased()] = parsed }
        }
        return index.anyProvider.isEmpty ? nil : index
    }

    static func parseModel(id: String, _ model: [String: Any]) -> Entry {
        let limit = model["limit"] as? [String: Any] ?? [:]
        let modalities = model["modalities"] as? [String: Any] ?? [:]

        func number(_ container: [String: Any], _ key: String) -> Int? {
            if let i = container[key] as? Int { return i }
            if let d = container[key] as? Double { return Int(d) }
            return nil
        }

        var pricing: Pricing?
        if let cost = model["cost"] as? [String: Any] {
            func money(_ key: String) -> Double? {
                if let d = cost[key] as? Double { return d }
                if let i = cost[key] as? Int { return Double(i) }
                return nil
            }
            let input = money("input"), output = money("output")
            if input != nil || output != nil {
                pricing = Pricing(inputPerMTok: input, outputPerMTok: output,
                                  cachedInputPerMTok: money("cache_read"),
                                  cacheWritePerMTok: money("cache_write"))
            }
        }

        var efforts: [String] = []
        for option in model["reasoning_options"] as? [[String: Any]] ?? [] {
            efforts += (option["values"] as? [String] ?? [])
        }

        // A model's own `id` field is authoritative; map keys are sometimes
        // namespaced by the provider that republishes it.
        var resolvedID = (model["id"] as? String) ?? id
        if let slash = resolvedID.lastIndex(of: "/") {
            resolvedID = String(resolvedID[resolvedID.index(after: slash)...])
        }

        return Entry(id: resolvedID,
                     name: model["name"] as? String,
                     family: model["family"] as? String,
                     summary: model["description"] as? String,
                     contextWindow: number(limit, "context"),
                     maxOutputTokens: number(limit, "output"),
                     inputModalities: modalities["input"] as? [String] ?? [],
                     outputModalities: modalities["output"] as? [String] ?? [],
                     toolCall: model["tool_call"] as? Bool ?? false,
                     reasoning: model["reasoning"] as? Bool ?? false,
                     structuredOutput: model["structured_output"] as? Bool ?? false,
                     // Absent means unconstrained, so default to accepting it.
                     temperature: model["temperature"] as? Bool ?? true,
                     reasoningEfforts: efforts,
                     pricing: pricing,
                     releaseDate: model["release_date"] as? String,
                     openWeights: model["open_weights"] as? Bool ?? false)
    }

    // MARK: - Test seams

    /// Loads an index directly, bypassing disk and network.
    @discardableResult
    public func loadForTesting(_ data: Data) -> Bool {
        guard var parsed = Self.parse(data) else { return false }
        parsed.fetchedAt = Date()
        lock.lock()
        index = parsed
        loadedFromDisk = true
        lock.unlock()
        return true
    }

    public func clearForTesting() {
        lock.lock()
        index = Index()
        loadedFromDisk = true
        lock.unlock()
    }
}
