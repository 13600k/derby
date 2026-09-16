import Foundation

/// Independent measurements of a model, as published by Artificial Analysis.
///
/// These are facts about the *weights*, not about an account: the same model
/// scores the same wherever it is served. They are therefore kept apart from
/// `ModelCapabilities` (what the router filters on) and from `TargetHealth`
/// (what Derby measured itself against one account) — a benchmark is a prior,
/// and Derby's own latency numbers always win once it has any.
///
/// Persisted on `PhysicalModel`, so every field is optional and decoded with
/// `decodeIfPresent`.
public struct ModelBenchmark: Codable, Sendable, Hashable {
    /// Artificial Analysis Intelligence Index, 0–100. The composite the site's
    /// leaderboard is ranked by, and the one thing here Derby routes on.
    public var intelligenceIndex: Double?
    public var codingIndex: Double?
    public var agenticIndex: Double?
    /// Median decode throughput, tokens/second.
    public var outputTokensPerSecond: Double?
    /// Median time to first token, seconds.
    public var timeToFirstTokenSeconds: Double?
    public var inputPricePerMTok: Double?
    public var outputPricePerMTok: Double?
    public var cachedInputPricePerMTok: Double?
    public var contextWindow: Int?
    /// Who made the weights, per the index — shown so a wrong match is visible.
    public var creator: String?
    /// The entry this was taken from, so the user can check the match.
    public var sourceSlug: String?
    public var sourceName: String?
    public var releaseDate: String?
    /// Index methodology version. Scores are only comparable within one major
    /// version, so a stored score without it cannot be interpreted later.
    public var indexVersion: String?
    public var fetchedAt: Date?

    public init(intelligenceIndex: Double? = nil, codingIndex: Double? = nil,
                agenticIndex: Double? = nil, outputTokensPerSecond: Double? = nil,
                timeToFirstTokenSeconds: Double? = nil, inputPricePerMTok: Double? = nil,
                outputPricePerMTok: Double? = nil, cachedInputPricePerMTok: Double? = nil,
                contextWindow: Int? = nil, creator: String? = nil, sourceSlug: String? = nil,
                sourceName: String? = nil, releaseDate: String? = nil,
                indexVersion: String? = nil, fetchedAt: Date? = nil) {
        self.intelligenceIndex = intelligenceIndex
        self.codingIndex = codingIndex
        self.agenticIndex = agenticIndex
        self.outputTokensPerSecond = outputTokensPerSecond
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
        self.cachedInputPricePerMTok = cachedInputPricePerMTok
        self.contextWindow = contextWindow
        self.creator = creator
        self.sourceSlug = sourceSlug
        self.sourceName = sourceName
        self.releaseDate = releaseDate
        self.indexVersion = indexVersion
        self.fetchedAt = fetchedAt
    }

    /// Compact one-line description for the model list.
    public var descriptors: [String] {
        var parts: [String] = []
        if let intelligenceIndex { parts.append(String(format: "AA %.0f", intelligenceIndex)) }
        if let outputTokensPerSecond { parts.append(String(format: "%.0f tok/s", outputTokensPerSecond)) }
        if let timeToFirstTokenSeconds { parts.append(String(format: "%.2fs ttft", timeToFirstTokenSeconds)) }
        return parts
    }

    public var isEmpty: Bool {
        intelligenceIndex == nil && codingIndex == nil && agenticIndex == nil
            && outputTokensPerSecond == nil && timeToFirstTokenSeconds == nil
            && inputPricePerMTok == nil && outputPricePerMTok == nil && contextWindow == nil
    }
}

/// Which Artificial Analysis tier the configured key is on. The free endpoint
/// omits the Pro-only fields (context window, parameter count, token counts)
/// rather than failing, so the difference is how much arrives, not whether.
public enum BenchmarkTier: String, Codable, Sendable, CaseIterable, Hashable {
    case free, pro
    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        }
    }
    public var path: String {
        switch self {
        case .free: return "/api/v2/language/models/free"
        case .pro: return "/api/v2/language/models"
        }
    }
}

/// Benchmark scores for models, fetched from Artificial Analysis and cached on
/// disk.
///
/// Sibling of `RemoteModelCatalog`, and deliberately separate from it: that
/// index says what a model *is* (window, modalities, parameters it rejects), and
/// the router cannot work without it. This one says how good a model is, which
/// nobody can measure from a model listing and which is otherwise a number the
/// user has to invent by hand for every model they add.
///
/// Nothing here is consulted on the request path. A benchmark is copied into a
/// model's own fields when the user asks for it, and routing then reads those
/// fields exactly as it reads anything the user typed — so a stale or wrong
/// score is visible and editable rather than applied invisibly forever.
public final class BenchmarkCatalog: @unchecked Sendable {
    public static let shared = BenchmarkCatalog()

    public static let host = "https://artificialanalysis.ai"
    /// The free tier allows 1,000 requests a day; the data moves weekly at most.
    public static let refreshInterval: TimeInterval = 24 * 3600

    public struct Entry: Sendable, Hashable {
        public var slug: String
        public var name: String
        public var creator: String?
        public var releaseDate: String?
        public var intelligenceIndex: Double?
        public var codingIndex: Double?
        public var agenticIndex: Double?
        public var outputTokensPerSecond: Double?
        public var timeToFirstTokenSeconds: Double?
        public var inputPricePerMTok: Double?
        public var outputPricePerMTok: Double?
        public var cachedInputPricePerMTok: Double?
        public var contextWindow: Int?

        public func benchmark(indexVersion: String?, fetchedAt: Date) -> ModelBenchmark {
            ModelBenchmark(intelligenceIndex: intelligenceIndex,
                           codingIndex: codingIndex,
                           agenticIndex: agenticIndex,
                           outputTokensPerSecond: outputTokensPerSecond,
                           timeToFirstTokenSeconds: timeToFirstTokenSeconds,
                           inputPricePerMTok: inputPricePerMTok,
                           outputPricePerMTok: outputPricePerMTok,
                           cachedInputPricePerMTok: cachedInputPricePerMTok,
                           contextWindow: contextWindow,
                           creator: creator,
                           sourceSlug: slug,
                           sourceName: name,
                           releaseDate: releaseDate,
                           indexVersion: indexVersion,
                           fetchedAt: fetchedAt)
        }
    }

    struct Index: Sendable {
        /// Normalized slug/name → entry.
        var byKey: [String: Entry] = [:]
        /// Order-independent token key → entry, so `claude-sonnet-4-5` finds
        /// the index's `claude-4-5-sonnet`.
        var byTokenKey: [String: Entry] = [:]
        /// Every row for one set of weights, keyed by the id with its
        /// reasoning-variant tokens removed and sorted strongest level first.
        /// The index splits a model across a row per reasoning level; a
        /// provider serves one endpoint that can be driven at any of them.
        var groups: [String: [Entry]] = [:]
        var all: [Entry] = []
        var indexVersion: String?
        var fetchedAt: Date?
        var count: Int { all.count }
    }

    private let lock = NSLock()
    private var index = Index()
    private var loadedFromDisk = false

    public var cacheURL: URL { AppPaths.supportDirectory.appendingPathComponent("benchmark-catalog.json") }

    private init() {}

    // MARK: - Loading

    private func ensureLoaded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        guard var parsed = Self.parse(data) else { return }
        parsed.fetchedAt = (try? FileManager.default
            .attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        index = parsed
    }

    public var status: (modelCount: Int, fetchedAt: Date?, indexVersion: String?) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return (index.count, index.fetchedAt, index.indexVersion)
    }

    public var isStale: Bool {
        let current = status
        guard let at = current.fetchedAt, current.modelCount > 0 else { return true }
        return Date().timeIntervalSince(at) > Self.refreshInterval
    }

    public var indexVersion: String? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return index.indexVersion
    }

    // MARK: - Lookup

    /// The index's entry for a provider's model id, or nil when nothing matches
    /// closely enough to be trusted.
    ///
    /// Precision matters more than coverage here: a wrong match writes a wrong
    /// intelligence score and wrong prices into a model the router then ranks
    /// by. So a match is only ever an exact one — of the whole id, of its tokens
    /// in any order, or of the weights behind it — and a fuzzy near-miss is
    /// reported as no match at all.
    ///
    /// Where the index splits one model across a row per reasoning level, an id
    /// that names a level gets that level and an id that names none gets the
    /// **strongest** row. A provider's id is the name of an endpoint, not of a
    /// setting: an OpenAI-compatible server offering `qwen3.8-27b` will run it
    /// at whatever effort the request asks for, so the ceiling is what that
    /// target can do. Scoring it by the index's no-reasoning row would rank the
    /// same weights far below an account that happens to spell the level out.
    public func lookup(_ modelID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard !index.all.isEmpty else { return nil }

        let tokens = Self.tokens(modelID)
        guard !tokens.isEmpty else { return nil }
        let requested = Self.reasoningRank(tokens)

        // An id that states its level is taken at its word, before any group is
        // consulted — `gpt-5-1-low` must never come back scored as `xhigh`.
        if requested != nil {
            if let hit = index.byKey[Self.normalize(modelID)] { return hit }
            if let hit = index.byTokenKey[Self.key(tokens)] { return hit }
        }

        guard let group = index.groups[Self.key(Self.strippingVariants(tokens))],
              !group.isEmpty else {
            // No group at all: an id that named a level has already missed, and
            // one that did not gets the same two exact chances it would have had.
            return index.byKey[Self.normalize(modelID)] ?? index.byTokenKey[Self.key(tokens)]
        }
        // Sorted strongest-first, so an unspecified id takes the ceiling.
        guard let requested else { return group[0] }
        // A level the index does not publish falls to the strongest below it,
        // and to the weakest published when it publishes nothing lower.
        return group.first { Self.reasoningRank($0) <= requested } ?? group.last
    }

    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return index.all
    }

    // MARK: - Normalisation

    /// How hard a model was driven, as a ladder.
    ///
    /// `max` is deliberately absent even though Derby's own effort ladder has
    /// it: the index never writes it as a level, while several real models are
    /// *named* `-max` (Qwen Max, Grok 4 Max). Folding those into their families
    /// would score one model with another's number.
    static let effortRanks: [String: Int] = [
        "minimal": 1, "low": 2, "medium": 3, "high": 4, "xhigh": 5,
    ]
    /// Tokens that name a reasoning level rather than a set of weights.
    static let variantTokens: Set<String> = Set(effortRanks.keys)
        .union(["reasoning", "nonreasoning", "non", "thinking", "effort"])
    /// Serving noise that never changes which weights answered.
    static let noiseTokens: Set<String> = [
        "latest", "preview", "exp", "experimental", "instruct", "it", "chat",
        "hf", "gguf", "mlx", "community", "online",
    ]

    /// The level stated in a piece of text, or nil when it states none.
    ///
    /// An explicit effort beats the generic reasoning marker, because rows
    /// carry both: `claude-fable-5-1-low` is named "(Adaptive Reasoning, Low
    /// Effort, …)", and reading "Reasoning" there would score it the same as
    /// its own high-effort sibling.
    static func level(inText text: String) -> Int? {
        var text = text.lowercased()
        // Negation first — "non-reasoning" contains "reasoning".
        for marker in ["non-reasoning", "nonreasoning", "non reasoning"] where text.contains(marker) {
            return 0
        }
        var best: Int?
        // Consumed before "high" is looked for, so "xhigh" is never read as it.
        if text.contains("xhigh") || text.contains("x-high") {
            best = 5
            text = text.replacingOccurrences(of: "xhigh", with: " ")
                       .replacingOccurrences(of: "x-high", with: " ")
        }
        // `max` is a level *here* — the index writes "Max Effort" in a name —
        // but never in a slug or a provider's id, where Qwen Max and Grok 4 Max
        // are model names.
        for (word, rank) in [("minimal", 1), ("low", 2), ("medium", 3), ("high", 4), ("max", 6)]
        where text.contains(word) {
            if best == nil || rank > best! { best = rank }
        }
        if let best { return best }
        if text.contains("reasoning") || text.contains("thinking") { return 4 }
        return nil
    }

    /// The level a *provider's model id* asks for, or nil when it names none.
    ///
    /// Nil is the case the user cannot control — a custom endpoint is just
    /// `qwen3.8-27b` — and is what resolves to the ceiling. An explicit
    /// `non-reasoning` is a level, and ranks bottom rather than unspecified.
    static func reasoningRank(_ tokens: [String]) -> Int? {
        if tokens.contains("nonreasoning") { return 0 }
        if let i = tokens.firstIndex(of: "non"), tokens.dropFirst(i + 1).first == "reasoning" { return 0 }
        if let best = tokens.compactMap({ effortRanks[$0] }).max() { return best }
        if tokens.contains("reasoning") || tokens.contains("thinking") { return 4 }
        return nil
    }

    /// The level an index row was measured at.
    ///
    /// Read from the name's trailing parenthetical, which is where this index
    /// actually states it — "Qwen3.8 27B (Non-reasoning)", "GPT-5.2 Codex
    /// (xhigh)". The slug is not reliable for this: the reasoning row is often
    /// the *bare* one (`qwen3-5-9b` is "(Reasoning)"), the level frequently
    /// appears in no slug at all (`gemini-3-5-flash` is "(high)"), and a slug
    /// token can belong to the model's own name — `mistral-medium-3-1` is
    /// Mistral Medium, not a medium-effort anything.
    static func statedLevel(_ entry: Entry) -> Int? {
        guard let open = entry.name.lastIndex(of: "("),
              let close = entry.name.lastIndex(of: ")"), open < close else { return nil }
        return level(inText: String(entry.name[entry.name.index(after: open)..<close]))
    }

    /// A row's level for ordering, treating one that states none as the model's
    /// plain baseline.
    static func reasoningRank(_ entry: Entry) -> Int { statedLevel(entry) ?? 0 }

    /// Lowercased, punctuation-collapsed form: `GPT-4.1` and `gpt_4_1` both
    /// become `gpt-4-1`, which is how the index spells its slugs.
    static func normalize(_ raw: String) -> String {
        var id = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Aggregators and local runners namespace the id by who published it.
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        // Bedrock: "us.anthropic.claude-sonnet-4-5-20250929-v1:0".
        for vendor in ["anthropic.", "meta.", "mistral.", "amazon.", "cohere.",
                       "deepseek.", "qwen.", "openai.", "ai21.", "writer."] {
            if let range = id.range(of: vendor) { id = String(id[range.upperBound...]); break }
        }
        if let range = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { id.removeSubrange(range) }

        var out = ""
        for character in id {
            if character.isLetter || character.isNumber { out.append(character) }
            else if !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out
    }

    static func tokens(_ raw: String) -> [String] {
        normalize(raw)
            .split(separator: "-")
            .map(String.init)
            .filter { !noiseTokens.contains($0) && !isDateStamp($0) }
    }

    /// The id with its reasoning level removed — the name of the weights.
    ///
    /// Never strips down to a single token: a one-token remainder is far more
    /// likely to be a family name that swallows unrelated models than a real
    /// grouping, and an over-wide group is how one model gets another's score.
    static func strippingVariants(_ tokens: [String]) -> [String] {
        let stripped = tokens.filter { !variantTokens.contains($0) }
        return stripped.count >= 2 || stripped.count == tokens.count ? stripped : tokens
    }

    /// The keys an index row should be grouped under: its id with the level it
    /// states removed, from both its slug and its name.
    ///
    /// A row that states no level is stripped of nothing, so `mistral-medium-3-1`
    /// stays Mistral Medium instead of joining a "Mistral 3.1" that may exist.
    static func baseKeys(for entry: Entry) -> [String] {
        let hasLevel = statedLevel(entry) != nil
        var keys: [String] = []
        let slugTokens = tokens(entry.slug)
        if !slugTokens.isEmpty {
            keys.append(key(hasLevel ? strippingVariants(slugTokens) : slugTokens))
        }
        // The parenthetical is the qualifier, so the name without it is the
        // model: "Qwen3.8 27B (Non-reasoning)" and the Reasoning row both
        // reduce to "Qwen3.8 27B".
        var name = entry.name
        if let open = name.lastIndex(of: "("), name.lastIndex(of: ")").map({ open < $0 }) == true {
            name = String(name[name.startIndex..<open])
        }
        let nameTokens = tokens(name)
        if !nameTokens.isEmpty {
            let base = key(hasLevel ? strippingVariants(nameTokens) : nameTokens)
            if !keys.contains(base) { keys.append(base) }
        }
        return keys
    }

    /// Order-independent key. Providers disagree about where the tier goes —
    /// Anthropic ships `claude-sonnet-4-5` while the index lists
    /// `claude-4-5-sonnet` — and that is the same model, not a near match.
    static func key(_ tokens: [String]) -> String { tokens.sorted().joined(separator: "-") }

    /// A release stamp: `20250929`, or `0624`.
    static func isDateStamp(_ token: String) -> Bool {
        guard token.allSatisfy(\.isNumber) else { return false }
        return token.count == 8 || token.count == 6
    }

    // MARK: - Refresh

    /// Downloads the index and rewrites the cache.
    ///
    /// The endpoint pages: it answers 200 rows and says how many pages there
    /// are. Reading only the first one silently hid three quarters of the index
    /// — including, for a model whose rows are split across pages, every
    /// reasoning level but the one that happened to land on page 1.
    ///
    /// A failure leaves the previous cache in place, so a refresh can never make
    /// Derby know less than it did.
    @discardableResult
    public func refresh(apiKey: String?,
                        tier: BenchmarkTier = .free,
                        transport: (any HTTPTransport)? = nil,
                        timeout: TimeInterval = 45,
                        maxPages: Int = 20) async -> Result<Int, DerbyError> {
        var headers = ["accept": "application/json"]
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            headers["x-api-key"] = apiKey.trimmingCharacters(in: .whitespaces)
        }
        let http = transport ?? URLSessionTransport.shared

        var rows: [[String: Any]] = []
        var seen = Set<String>()
        var version: Any?
        var page = 1
        var totalPages = 1

        while page <= totalPages && page <= maxPages {
            guard var components = URLComponents(string: Self.host + tier.path) else {
                return .failure(DerbyError(kind: .invalidRequest, message: "Invalid benchmark catalog URL."))
            }
            // The first request is sent unadorned, so a server that does not
            // page is asked exactly what it was asked before.
            if page > 1 { components.queryItems = [URLQueryItem(name: "page", value: String(page))] }
            guard let url = components.url else {
                return .failure(DerbyError(kind: .invalidRequest, message: "Invalid benchmark catalog URL."))
            }

            let response: OutboundResponse
            do {
                response = try await http.send(
                    OutboundRequest(url: url, method: "GET", headers: headers, timeout: timeout))
            } catch let error as DerbyError {
                if page > 1 { break }          // keep the pages already in hand
                return .failure(error)
            } catch {
                if page > 1 { break }
                return .failure(DerbyError(kind: .transient, message: error.localizedDescription))
            }
            guard (200..<300).contains(response.status) else {
                if page > 1 { break }
                return .failure(DerbyError(kind: Self.kind(for: response.status),
                                           message: Self.message(for: response.status),
                                           providerStatus: response.status))
            }
            guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let batch = root["data"] as? [[String: Any]] else {
                if page > 1 { break }
                return .failure(DerbyError(kind: .transient,
                                           message: "The benchmark catalog was not in the expected format."))
            }
            if version == nil { version = root["intelligence_index_version"] }

            var added = 0
            for row in batch {
                let slug = ((row["slug"] as? String) ?? (row["id"] as? String) ?? "").lowercased()
                guard slug.isEmpty || seen.insert(slug).inserted else { continue }
                rows.append(row)
                added += 1
            }
            if let pagination = root["pagination"] as? [String: Any],
               let stated = pagination["total_pages"] as? Int {
                totalPages = max(totalPages, stated)
            }
            // A later page that repeats what page 1 held means the server
            // ignored the parameter. Stop rather than fetch the same rows N
            // times against a quota that is counted per request.
            if page > 1 && added == 0 { break }
            if batch.isEmpty { break }
            page += 1
        }

        guard !rows.isEmpty else {
            return .failure(DerbyError(kind: .transient,
                                       message: "The benchmark catalog was not in the expected format."))
        }

        // Cached as one document of every page, so loading from disk needs to
        // know nothing about paging.
        var merged: [String: Any] = ["data": rows]
        if let version { merged["intelligence_index_version"] = version }
        guard let body = try? JSONSerialization.data(withJSONObject: merged),
              var parsed = Self.parse(body) else {
            return .failure(DerbyError(kind: .transient,
                                       message: "The benchmark catalog was not in the expected format."))
        }
        parsed.fetchedAt = Date()
        lock.lock()
        index = parsed
        loadedFromDisk = true
        let count = index.count
        lock.unlock()
        try? body.write(to: cacheURL, options: .atomic)
        return .success(count)
    }

    static func kind(for status: Int) -> FailureKind {
        switch status {
        case 401, 403: return .authentication
        case 429: return .rateLimit
        default: return .transient
        }
    }

    static func message(for status: Int) -> String {
        switch status {
        case 401, 403:
            return "Artificial Analysis rejected the API key. Check it in Settings → Benchmarks, or create one at artificialanalysis.ai."
        case 429:
            return "Artificial Analysis rate-limited this key (the free tier allows 1,000 requests a day). The cached scores are unchanged."
        default:
            return "The benchmark catalog request failed (HTTP \(status))."
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Index? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let rows = root["data"] as? [[String: Any]] else { return nil }

        var index = Index()
        if let version = root["intelligence_index_version"] {
            index.indexVersion = describeVersion(version)
        }
        for row in rows {
            guard let entry = parseModel(row) else { continue }
            index.all.append(entry)

            // First writer wins on every key, after sorting so the plainest
            // variant of a model is the one a bare id resolves to: the index
            // lists `claude-4-5-sonnet` and `claude-4-5-sonnet-thinking`, and a
            // provider's `claude-sonnet-4-5` means the former.
            for alias in [normalize(entry.slug), normalize(entry.name)] where !alias.isEmpty {
                if index.byKey[alias] == nil { index.byKey[alias] = entry }
            }
        }
        // Shortest id first, so a plain model wins its shared token key over a
        // variant of it. Sorted rather than compared pairwise so the result does
        // not depend on the order the endpoint happened to return rows in.
        for entry in index.all.sorted(by: { ($0.slug.count, $0.slug) < ($1.slug.count, $1.slug) }) {
            for source in [entry.slug, entry.name] {
                let tokens = tokens(source)
                guard !tokens.isEmpty else { continue }
                let full = key(tokens)
                if index.byTokenKey[full] == nil { index.byTokenKey[full] = entry }
            }
            for base in baseKeys(for: entry) {
                var group = index.groups[base] ?? []
                // Slug and name usually reduce to the same key; one row must
                // not appear twice in its own group.
                if !group.contains(where: { $0.slug == entry.slug }) {
                    group.append(entry)
                    index.groups[base] = group
                }
            }
        }
        // Strongest reasoning level first, so an id that names none takes the
        // ceiling by reading the head of the list. Ties break on the score, then
        // on the slug, so the order never depends on how the rows arrived.
        for (base, group) in index.groups {
            index.groups[base] = group.sorted { a, b in
                let (rankA, rankB) = (reasoningRank(a), reasoningRank(b))
                if rankA != rankB { return rankA > rankB }
                let (scoreA, scoreB) = (a.intelligenceIndex ?? -1, b.intelligenceIndex ?? -1)
                if scoreA != scoreB { return scoreA > scoreB }
                return a.slug < b.slug
            }
        }
        return index.all.isEmpty ? nil : index
    }

    /// The endpoint has published the index version as both a number and a
    /// string; either way it is only ever displayed.
    static func describeVersion(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return d == d.rounded() ? String(Int(d)) : String(d) }
        return nil
    }

    static func parseModel(_ row: [String: Any]) -> Entry? {
        let slug = (row["slug"] as? String) ?? (row["id"] as? String) ?? ""
        let name = (row["name"] as? String) ?? slug
        guard !slug.isEmpty || !name.isEmpty else { return nil }

        // `evaluations` and `pricing` are nested objects, but the same fields
        // have also been published flat on the row. Read either shape rather
        // than silently importing a model with no score at all.
        let evaluations = row["evaluations"] as? [String: Any] ?? [:]
        let pricing = row["pricing"] as? [String: Any] ?? [:]

        func double(_ key: String, _ containers: [[String: Any]]) -> Double? {
            for container in containers {
                if let d = container[key] as? Double { return d }
                if let i = container[key] as? Int { return Double(i) }
            }
            return nil
        }
        func int(_ key: String, _ containers: [[String: Any]]) -> Int? {
            double(key, containers).map { Int($0) }
        }

        let creator: String?
        if let nested = row["model_creator"] as? [String: Any] {
            creator = (nested["name"] as? String) ?? (nested["slug"] as? String)
        } else {
            creator = row["model_creator"] as? String
        }

        return Entry(
            slug: slug.isEmpty ? name : slug,
            name: name.isEmpty ? slug : name,
            creator: creator,
            releaseDate: row["release_date"] as? String,
            intelligenceIndex: double("artificial_analysis_intelligence_index", [evaluations, row]),
            codingIndex: double("artificial_analysis_coding_index", [evaluations, row]),
            agenticIndex: double("artificial_analysis_agentic_index", [evaluations, row]),
            outputTokensPerSecond: double("median_output_tokens_per_second", [row, evaluations]),
            timeToFirstTokenSeconds: double("median_time_to_first_token_seconds", [row, evaluations]),
            inputPricePerMTok: double("price_1m_input_tokens", [pricing, row]),
            outputPricePerMTok: double("price_1m_output_tokens", [pricing, row]),
            cachedInputPricePerMTok: double("price_1m_cache_hit_tokens", [pricing, row]),
            // Pro tier only; absent on free, which is why it is never required.
            contextWindow: int("context_window_tokens", [row, pricing]))
    }

    // MARK: - Test seams

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

/// Copies an index entry into the fields of a configured model.
///
/// A pure function of (entry, model, settings), like the router is of (request,
/// snapshot, config) — so what a button press will write can be tested, and
/// shown, without fetching anything.
public enum BenchmarkApplication {
    /// One field a fetch changed, kept so the result is reportable rather than a
    /// silent rewrite of numbers the user chose.
    public struct Change: Sendable, Hashable {
        public var field: String
        public var before: String?
        public var after: String
        public var description: String {
            guard let before, before != after else { return "\(field) → \(after)" }
            return "\(field) \(before) → \(after)"
        }
    }

    /// What happened to one model.
    public struct Outcome: Sendable, Hashable {
        public var modelID: String
        /// Nil when the index has nothing for this model.
        public var matched: String?
        public var changes: [Change]
        public var isMatched: Bool { matched != nil }
    }

    /// Applies `entry` to `model`, returning what changed.
    ///
    /// `knownContextWindow` is the window Derby already has from the provider or
    /// its catalogs; the index's own figure only ever fills a gap, because a
    /// benchmark row describes a model in general while a provider states what
    /// *this* endpoint will actually accept.
    @discardableResult
    public static func apply(_ entry: BenchmarkCatalog.Entry,
                             to model: inout PhysicalModel,
                             kind: ProviderKind,
                             settings: BenchmarkSettings,
                             knownContextWindow: Int?,
                             indexVersion: String?,
                             now: Date = Date()) -> [Change] {
        var changes: [Change] = []

        // Always recorded, even when no field below is written: it is the
        // evidence for what was matched and when, and the only way to tell a
        // model nobody has fetched from one the index simply scores the same.
        model.benchmark = entry.benchmark(indexVersion: indexVersion, fetchedAt: now)

        if settings.applyIntelligenceScore, let score = entry.intelligenceIndex {
            let clamped = min(100, max(0, score))
            if abs(clamped - model.qualityScore) >= 0.5 {
                changes.append(Change(field: "intelligence score",
                                      before: String(Int(model.qualityScore.rounded())),
                                      after: String(Int(clamped.rounded()))))
            }
            model.qualityScore = clamped
        }

        // A flat-rate target has no marginal cost per token, whatever the hosted
        // copy of the same weights is billed at. Writing the index's prices onto
        // a local server would make cost-aware routing avoid the one target that
        // is actually free.
        if settings.applyPricing, !kind.isLocal, !kind.isSubscription {
            var pricing = model.pricingOverride ?? Pricing()
            var wrote = false
            if let input = entry.inputPricePerMTok,
               settings.overwriteExistingPricing || pricing.inputPerMTok == nil,
               pricing.inputPerMTok != input {
                changes.append(Change(field: "input $/Mtok",
                                      before: pricing.inputPerMTok.map { fmt($0) },
                                      after: fmt(input)))
                pricing.inputPerMTok = input
                wrote = true
            }
            if let output = entry.outputPricePerMTok,
               settings.overwriteExistingPricing || pricing.outputPerMTok == nil,
               pricing.outputPerMTok != output {
                changes.append(Change(field: "output $/Mtok",
                                      before: pricing.outputPerMTok.map { fmt($0) },
                                      after: fmt(output)))
                pricing.outputPerMTok = output
                wrote = true
            }
            if let cached = entry.cachedInputPricePerMTok,
               settings.overwriteExistingPricing || pricing.cachedInputPerMTok == nil,
               pricing.cachedInputPerMTok != cached {
                changes.append(Change(field: "cached input $/Mtok",
                                      before: pricing.cachedInputPerMTok.map { fmt($0) },
                                      after: fmt(cached)))
                pricing.cachedInputPerMTok = cached
                wrote = true
            }
            if wrote { model.pricingOverride = pricing }
        }

        // Only ever fills a blank. A window the provider stated is what that
        // endpoint enforces; the index's is what the model can do somewhere.
        if settings.applyContextWindow, knownContextWindow == nil,
           model.capabilityOverrides.contextWindow == nil,
           let window = entry.contextWindow, window > 0 {
            changes.append(Change(field: "context window", before: nil, after: window.formattedTokens))
            model.capabilityOverrides.contextWindow = window
        }

        return changes
    }

    private static func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}
