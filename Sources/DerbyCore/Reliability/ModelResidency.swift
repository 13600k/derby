import Foundation

/// Whether a target can answer without first loading its model.
///
/// A local server holds a handful of models in memory and loads the rest on
/// demand, which for a large model takes longer than a first-token timeout.
/// Two copies of the same model — the same weights on two servers, or two
/// quantizations on one — are interchangeable for the answer but not for the
/// wait, so routing prefers the one already loaded.
public enum ModelWarmth: String, Codable, Sendable, Hashable {
    /// The server reports the model in memory.
    case loaded
    /// No fresh report, but it answered recently enough to still be loaded.
    case recentlyUsed = "recently_used"
    /// The server reports it is not in memory.
    case cold
    /// Hosted models are always ready.
    case alwaysAvailable = "always_available"
    case unknown

    public var isWarm: Bool { self == .loaded || self == .recentlyUsed || self == .alwaysAvailable }

    /// Contribution to the `warmth` score dimension.
    public var score: Double {
        switch self {
        case .loaded, .alwaysAvailable: return 1.0
        case .recentlyUsed: return 0.85
        case .unknown: return 0.6
        case .cold: return 0.25
        }
    }

    public var displayName: String {
        switch self {
        case .loaded: return "loaded"
        case .recentlyUsed: return "recently used"
        case .cold: return "not loaded"
        case .alwaysAvailable: return "hosted"
        case .unknown: return "load state unknown"
        }
    }
}

/// What a server says it is doing right now.
///
/// Derby's own in-flight counts only see requests Derby sent. A serving engine
/// knows about all of them — another client's, a teammate's, a script's — and
/// about the hardware underneath: how many decoding slots are busy and how full
/// the KV cache is. Where a server reports that, it is better information than
/// anything Derby can infer, so routing prefers it.
public struct ServerOccupancy: Sendable, Hashable, Codable {
    /// Requests the server is decoding right now.
    public var running: Int?
    /// Requests accepted but not yet started.
    public var queued: Int?
    /// How many requests it can decode at once (llama.cpp calls these slots).
    public var totalSlots: Int?
    /// Share of the KV cache in use, 0…1 — the closest thing to a GPU gauge a
    /// serving engine exposes, and what actually runs out first.
    public var kvCacheUsage: Double?

    public init(running: Int? = nil, queued: Int? = nil, totalSlots: Int? = nil, kvCacheUsage: Double? = nil) {
        self.running = running; self.queued = queued
        self.totalSlots = totalSlots; self.kvCacheUsage = kvCacheUsage
    }

    public var isEmpty: Bool {
        running == nil && queued == nil && totalSlots == nil && kvCacheUsage == nil
    }

    /// Committed share of the server's own capacity, 0…1, from whichever
    /// measure it gave.
    public var utilization: Double? {
        if let running, let totalSlots, totalSlots > 0 {
            return min(1, Double(running + (queued ?? 0)) / Double(totalSlots))
        }
        if let kvCacheUsage { return min(1, max(0, kvCacheUsage)) }
        if let queued, queued > 0 { return 1 }
        if let running, running > 0 { return 0.5 }   // busy, but it did not say how busy
        return nil
    }

    /// Nothing more can start without waiting: every slot taken, work already
    /// queued, or the cache that holds a conversation effectively full.
    public var isSaturated: Bool {
        if let queued, queued > 0 { return true }
        if let running, let totalSlots, totalSlots > 0, running >= totalSlots { return true }
        if let kvCacheUsage, kvCacheUsage >= 0.98 { return true }
        return false
    }

    /// "3 of 4 slots busy, 2 queued, KV cache 87%" — for an exclusion reason.
    public var summary: String {
        var parts: [String] = []
        if let running, let totalSlots { parts.append("\(running) of \(totalSlots) slots busy") }
        else if let running { parts.append("\(running) running") }
        if let queued, queued > 0 { parts.append("\(queued) queued") }
        if let kvCacheUsage { parts.append("KV cache \(Int((kvCacheUsage * 100).rounded()))%") }
        return parts.isEmpty ? "no free capacity" : parts.joined(separator: ", ")
    }
}

/// What one local server last reported: which models it holds, what it is
/// working on, and when it said so. Either half may be missing — servers differ
/// in what they publish.
public struct AccountResidency: Sendable, Hashable {
    public var loadedModels: Set<String>?
    public var occupancy: ServerOccupancy?
    public var observedAt: Date

    public init(loadedModels: Set<String>? = nil, occupancy: ServerOccupancy? = nil,
                observedAt: Date = Date()) {
        self.loadedModels = loadedModels.map { Set($0.map(ModelResidency.normalize)) }
        self.occupancy = occupancy
        self.observedAt = observedAt
    }

    public func contains(_ modelID: String) -> Bool {
        loadedModels?.contains(ModelResidency.normalize(modelID)) ?? false
    }
}

public enum ModelResidency {
    /// A report older than this is not trusted; the poller refreshes well within it.
    public static let freshness: TimeInterval = 30
    /// Ollama unloads an idle model after five minutes by default, so a target
    /// that answered more recently than this is probably still loaded.
    public static let recentUseWindow: TimeInterval = 240
    public static let pollInterval: TimeInterval = 5

    /// Ollama treats "qwen3" and "qwen3:latest" as one model.
    static func normalize(_ id: String) -> String {
        let lower = id.lowercased().trimmingCharacters(in: .whitespaces)
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        return name.contains(":") ? lower : lower + ":latest"
    }
}

/// Holds the most recent loaded-model report from each local server. Written by
/// the engine's poller, read into every routing snapshot.
public actor ResidencyRegistry {
    private var accounts: [UUID: AccountResidency] = [:]

    public init() {}

    public func update(accountID: UUID, loadedModels: Set<String>? = nil,
                       occupancy: ServerOccupancy? = nil, at date: Date = Date()) {
        accounts[accountID] = AccountResidency(loadedModels: loadedModels, occupancy: occupancy,
                                               observedAt: date)
    }

    /// The server could not be asked; stop trusting what it said before.
    public func forget(accountID: UUID) {
        accounts.removeValue(forKey: accountID)
    }

    public func snapshot() -> [UUID: AccountResidency] { accounts }
}
