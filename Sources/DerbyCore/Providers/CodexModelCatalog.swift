import Foundation

/// Reads the model catalog the Codex CLI caches locally.
///
/// The ChatGPT/Codex backend publishes no model-listing endpoint Derby can call,
/// and a hardcoded list goes stale the moment OpenAI ships a new family. The CLI
/// already fetches and caches the real catalog at `~/.codex/models_cache.json`,
/// so Derby reads that rather than guessing.
public enum CodexModelCatalog {

    public struct Entry: Sendable, Hashable {
        public var slug: String
        public var displayName: String
        public var description: String
        public var supportedEfforts: [String]
        public var defaultEffort: String?
        /// The CLI's own ranking; 1 is the flagship.
        public var priority: Int
        /// `hide` marks internal models the CLI does not offer.
        public var isListed: Bool
        public var supportedInAPI: Bool
        /// The window the CLI actually works to, and the ceiling the model
        /// supports. The backend publishes both; Derby reports the larger as the
        /// model's capability and leaves the CLI's working figure alone.
        public var contextWindow: Int?
        public var maxContextWindow: Int?

        /// Quality derived from the provider's own ordering rather than invented.
        public var derivedQuality: Double {
            Double(max(50, 96 - min(45, priority)))
        }
    }

    public struct Catalog: Sendable {
        public var entries: [Entry]
        public var fetchedAt: Date?
        public var clientVersion: String?
    }

    /// Each Codex home caches its own catalog, so an account signed into a
    /// separate `CODEX_HOME` gets that account's model list.
    public static func cacheURL(home: URL? = nil) -> URL {
        (home ?? CLICredentialReader.defaultHome(for: .codexCLI))
            .appendingPathComponent("models_cache.json")
    }
    public static var cacheURL: URL { cacheURL(home: nil) }

    private static let lock = NSLock()
    private static var cached: [String: (catalog: Catalog, modified: Date)] = [:]

    /// Parsed catalog, re-read whenever the CLI rewrites the file.
    public static func load(home: URL? = nil) -> Catalog? {
        lock.lock()
        defer { lock.unlock() }

        let url = cacheURL(home: home)
        let cacheKey = url.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        if let hit = cached[cacheKey], let modified, hit.modified == modified { return hit.catalog }

        guard let catalog = Self.parse(contentsOf: url) else { return nil }
        if let modified { cached[cacheKey] = (catalog, modified) }
        return catalog
    }

    /// Parses a catalog file. Separate from `load()` so it can be tested against
    /// a fixture rather than the real `$HOME`.
    public static func parse(contentsOf url: URL) -> Catalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Parses the catalog payload. The CLI writes the backend's own response to
    /// disk unchanged, so the same parser reads the file and the live reply.
    public static func parse(_ data: Data) -> Catalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["models"] as? [[String: Any]] else { return nil }

        let entries: [Entry] = raw.compactMap { item in
            guard let slug = item["slug"] as? String, !slug.isEmpty else { return nil }
            let efforts = (item["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { $0["effort"] as? String }
            return Entry(slug: slug,
                         displayName: item["display_name"] as? String ?? slug,
                         description: item["description"] as? String ?? "",
                         supportedEfforts: efforts,
                         defaultEffort: item["default_reasoning_level"] as? String,
                         priority: item["priority"] as? Int ?? 99,
                         isListed: (item["visibility"] as? String ?? "list") == "list",
                         supportedInAPI: item["supported_in_api"] as? Bool ?? true,
                         contextWindow: item["context_window"] as? Int,
                         maxContextWindow: item["max_context_window"] as? Int)
        }
        guard !entries.isEmpty else { return nil }

        var fetchedAt: Date?
        if let stamp = root["fetched_at"] as? String {
            fetchedAt = ISO8601DateFormatter().date(from: stamp)
                ?? ISO8601DateFormatter.withFractionalSeconds.date(from: stamp)
        }
        return Catalog(entries: entries.sorted { $0.priority < $1.priority },
                       fetchedAt: fetchedAt,
                       clientVersion: root["client_version"] as? String)
    }

    /// Catalogs fetched live from the backend, by Codex home.
    private static var live: [String: Catalog] = [:]

    /// Remembers what the backend just reported, so request-time lookups
    /// describe the same models discovery listed — including one the CLI's file
    /// has never seen, whose reasoning levels would otherwise be unknown.
    public static func store(_ catalog: Catalog, home: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        live[cacheURL(home: home).path] = catalog
    }

    /// The best catalog available for a home: what the backend last told us,
    /// else what the CLI cached.
    public static func catalog(home: URL? = nil) -> Catalog? {
        lock.lock()
        let fetched = live[cacheURL(home: home).path]
        lock.unlock()
        return fetched ?? load(home: home)
    }

    /// Models Derby should offer: listed, API-capable, best first.
    public static func selectableModels(home: URL? = nil) -> [Entry] {
        (catalog(home: home)?.entries ?? []).filter { $0.isListed && $0.supportedInAPI }
    }

    public static func entry(for slug: String, home: URL? = nil) -> Entry? {
        catalog(home: home)?.entries.first { $0.slug == slug }
    }

    /// Clamps a requested effort to what a specific model actually accepts, so a
    /// level this model has never heard of does not become a 400.
    public static func clampEffort(_ effort: ReasoningEffort, for slug: String, home: URL? = nil) -> String {
        clampEffort(effort, for: slug, in: catalog(home: home))
    }

    public static func clampEffort(_ effort: ReasoningEffort, for slug: String, in catalog: Catalog?) -> String {
        guard let entry = catalog?.entries.first(where: { $0.slug == slug }),
              !entry.supportedEfforts.isEmpty else { return effort.rawValue }
        if entry.supportedEfforts.contains(effort.rawValue) { return effort.rawValue }
        // Walk down the requested scale to the strongest level this model has.
        let descending = ReasoningEffort.descendingFrom(effort)
        for candidate in descending where entry.supportedEfforts.contains(candidate.rawValue) {
            return candidate.rawValue
        }
        return entry.defaultEffort ?? entry.supportedEfforts.first ?? effort.rawValue
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
