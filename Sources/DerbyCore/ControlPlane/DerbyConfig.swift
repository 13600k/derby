import Foundation

/// The complete persisted control-plane state. Versioned: `ConfigMigrator`
/// upgrades older documents in place so a newer Derby can always read them.
public struct DerbyConfig: Codable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var gateway: GatewaySettings
    public var providers: [ProviderAccount]
    public var logicalModels: [LogicalModel]
    public var health: HealthSettings
    public var logging: LoggingSettings
    public var app: AppSettings
    /// What a benchmark fetch writes into a model. Nothing is ever fetched
    /// without the user asking; this only says what a request would apply.
    public var benchmarks: BenchmarkSettings
    /// Pricing overrides keyed by "<providerID>/<modelID>", applied on top of
    /// catalog pricing. Per-model overrides live on the model itself; this map
    /// exists so import/export can carry pricing without the rest of the model.
    public var pricingOverrides: [String: Pricing]
    public var updatedAt: Date

    public init(schemaVersion: Int = DerbyConfig.currentSchemaVersion,
                gateway: GatewaySettings = .default,
                providers: [ProviderAccount] = [],
                logicalModels: [LogicalModel] = [],
                health: HealthSettings = .default,
                logging: LoggingSettings = .default,
                app: AppSettings = .default,
                benchmarks: BenchmarkSettings = .default,
                pricingOverrides: [String: Pricing] = [:],
                updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.gateway = gateway
        self.providers = providers
        self.logicalModels = logicalModels
        self.health = health
        self.logging = logging
        self.app = app
        self.benchmarks = benchmarks
        self.pricingOverrides = pricingOverrides
        self.updatedAt = updatedAt
    }

    /// Sections that failed to decode and fell back to a default. Not persisted —
    /// it exists so the failure is reported rather than silently swallowed.
    public private(set) var decodeFailures: [String] = []

    // Decoding is tolerant: every section falls back to its default so a
    // partially-hand-edited or older config still loads.
    //
    // Tolerance without reporting is dangerous, though. A non-optional property
    // added to a persisted type once made the whole `providers` array
    // undecodable, and this initializer quietly replaced five configured
    // providers with an empty list — data loss with no symptom beyond an app
    // that had forgotten everything. Each fallback is now recorded.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var failures: [String] = []

        func decode<T: Decodable>(_ type: T.Type, _ key: CodingKeys, default fallback: T,
                                  label: String) -> T {
            guard c.contains(key) else { return fallback }
            do { return try c.decode(type, forKey: key) }
            catch {
                failures.append("\(label): \(error)")
                return fallback
            }
        }

        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        gateway = decode(GatewaySettings.self, .gateway, default: .default, label: "gateway settings")
        providers = decode([ProviderAccount].self, .providers, default: [], label: "providers")
        logicalModels = decode([LogicalModel].self, .logicalModels, default: [], label: "logical models")
        health = decode(HealthSettings.self, .health, default: .default, label: "health settings")
        logging = decode(LoggingSettings.self, .logging, default: .default, label: "logging settings")
        app = decode(AppSettings.self, .app, default: .default, label: "application settings")
        benchmarks = decode(BenchmarkSettings.self, .benchmarks, default: .default,
                            label: "benchmark settings")
        pricingOverrides = decode([String: Pricing].self, .pricingOverrides, default: [:],
                                  label: "pricing overrides")
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
        decodeFailures = failures
    }

    // MARK: - Lookups

    public func provider(id: UUID) -> ProviderAccount? { providers.first { $0.id == id } }
    public func logicalModel(named name: String) -> LogicalModel? {
        logicalModels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    public func logicalModel(id: UUID) -> LogicalModel? { logicalModels.first { $0.id == id } }

    /// Resolves a target reference into the concrete objects it points at.
    public func resolve(_ ref: TargetRef) -> (provider: ProviderAccount, model: PhysicalModel)? {
        guard let p = provider(id: ref.providerID), let m = p.model(id: ref.modelUUID) else { return nil }
        return (p, m)
    }

    /// A name is available if no other logical model uses it.
    public func isLogicalModelNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        return !logicalModels.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame && $0.id != id }
    }

    /// Every secret reference the config depends on, used to prune the Keychain.
    public var allSecretRefs: [SecretRef] {
        providers.flatMap { $0.auth.secretRefs } + [gateway.localKeyRef, benchmarks.apiKeyRef]
    }

    // MARK: - Seeds

    /// The starter set of logical models. Each one deliberately uses a different
    /// strategy so the per-logical-model policy design is visible immediately.
    public static func defaultLogicalModels() -> [LogicalModel] {
        [
            LogicalModel(
                name: "smart",
                summary: "Highest quality available. Falls back down the quality ladder.",
                policy: RoutingPolicy(strategy: .weightedScore, scoreWeights: .qualityFirst),
                retry: RetryConfig(maxRetriesPerTarget: 1),
                timeouts: TimeoutConfig(overallSeconds: 180, perAttemptSeconds: 120, firstTokenSeconds: 60)),
            LogicalModel(
                name: "fast",
                summary: "Lowest time-to-first-token. Small models preferred.",
                policy: RoutingPolicy(strategy: .lowestLatency, scoreWeights: .fast, latencyMetric: .timeToFirstToken),
                retry: RetryConfig(maxRetriesPerTarget: 0),
                timeouts: TimeoutConfig(overallSeconds: 45, perAttemptSeconds: 20, firstTokenSeconds: 10)),
            LogicalModel(
                name: "cheap",
                summary: "Lowest expected cost per request; free and local targets first.",
                policy: RoutingPolicy(strategy: .lowestCost, scoreWeights: .cheap),
                timeouts: TimeoutConfig(overallSeconds: 120, perAttemptSeconds: 60, firstTokenSeconds: 45)),
            LogicalModel(
                name: "coding",
                summary: "Tool-calling coding work. Blend of quality, health and latency.",
                policy: RoutingPolicy(strategy: .weightedScore,
                                      scoreWeights: ScoreWeights(quality: 0.40, latency: 0.20, cost: 0.10,
                                                                 health: 0.20, quota: 0.10)),
                retry: RetryConfig(maxRetriesPerTarget: 1),
                failover: FailoverConfig(enabled: true, maxAttempts: 4),
                timeouts: TimeoutConfig(overallSeconds: 300, perAttemptSeconds: 180, firstTokenSeconds: 60)),
            LogicalModel(
                name: "local",
                summary: "Never leaves this machine. Local model servers only.",
                policy: RoutingPolicy(strategy: .localFirst),
                failover: FailoverConfig(enabled: true, maxAttempts: 3),
                timeouts: TimeoutConfig(overallSeconds: 600, perAttemptSeconds: 300, firstTokenSeconds: 120)),
        ]
    }

    public static func seeded() -> DerbyConfig {
        DerbyConfig(logicalModels: defaultLogicalModels())
    }
}

/// Upgrades persisted documents across schema versions.
public enum ConfigMigrator {
    /// Applies every migration needed to bring `json` to the current version.
    /// Operates on the raw object so it can run before typed decoding, which is
    /// what makes renames and restructures possible.
    public static func migrate(rawObject: inout [String: Any]) -> [String] {
        var notes: [String] = []
        var version = (rawObject["schemaVersion"] as? Int) ?? 1

        // 1 → 2: the gateway no longer asks clients for a key. A loopback-only
        // gateway is reachable by anything already running as this user, so the
        // key bought nothing and cost every client a second setting. Configs
        // that opted into a non-loopback bind keep it — there the key is the
        // only thing standing between Derby and the LAN.
        if version == 1 {
            if var gateway = rawObject["gateway"] as? [String: Any],
               gateway["requireAPIKey"] as? Bool == true {
                let bind = (gateway["bindAddress"] as? String) ?? "127.0.0.1"
                let remote = (gateway["allowRemoteAccess"] as? Bool) ?? false
                if !remote && GatewaySettings.isLoopback(bind) {
                    gateway["requireAPIKey"] = false
                    rawObject["gateway"] = gateway
                    notes.append("Clients no longer need Derby's local API key — the base URL is enough. Re-enable it in Settings → Access if you want it back.")
                } else {
                    notes.append("Derby now defaults to no client API key, but this gateway is reachable beyond 127.0.0.1, so the key requirement was left on.")
                }
            }
            version = 2
        }

        // 2 → 3: a provider's timeouts used to be a ceiling only — routing took
        // `min(logical model, provider)`, so raising an account to 600 s did
        // nothing while its logical model still said 120 s, and there was no
        // provider-level first-token setting at all. Both now say how long the
        // endpoint needs. Accounts written before this have no first-token value
        // to say it with, so kinds that are slow to speak are given their
        // declared one; anything the user typed is left exactly as it is.
        if version == 2 {
            if var providers = rawObject["providers"] as? [[String: Any]] {
                var filled: [String] = []
                for i in providers.indices {
                    guard providers[i]["firstTokenTimeoutSeconds"] == nil,
                          let raw = providers[i]["kind"] as? String,
                          let kind = ProviderKind(rawValue: raw),
                          let stated = kind.defaultTimeouts.firstTokenSeconds else { continue }
                    providers[i]["firstTokenTimeoutSeconds"] = stated
                    filled.append((providers[i]["name"] as? String) ?? kind.displayName)
                }
                if !filled.isEmpty {
                    rawObject["providers"] = providers
                    notes.append("A provider's timeouts now lengthen what a logical model allows one attempt, instead of only shortening it. \(filled.joined(separator: ", ")) were given a first-token timeout to match, since a server that prefills a long conversation can be silent for minutes before it answers.")
                }
            }
            version = 3
        }

        if version > DerbyConfig.currentSchemaVersion {
            notes.append("Configuration was written by a newer version of Derby (schema \(version)); unknown fields were preserved where possible.")
            version = DerbyConfig.currentSchemaVersion
        }
        rawObject["schemaVersion"] = version
        return notes
    }
}
