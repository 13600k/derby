import Foundation

/// The complete persisted control-plane state. Versioned: `ConfigMigrator`
/// upgrades older documents in place so a newer Derby can always read them.
public struct DerbyConfig: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var gateway: GatewaySettings
    public var providers: [ProviderAccount]
    public var logicalModels: [LogicalModel]
    public var health: HealthSettings
    public var logging: LoggingSettings
    public var app: AppSettings
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
                pricingOverrides: [String: Pricing] = [:],
                updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.gateway = gateway
        self.providers = providers
        self.logicalModels = logicalModels
        self.health = health
        self.logging = logging
        self.app = app
        self.pricingOverrides = pricingOverrides
        self.updatedAt = updatedAt
    }

    // Decoding is tolerant: every section falls back to its default so a
    // partially-hand-edited or older config still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        gateway = (try? c.decode(GatewaySettings.self, forKey: .gateway)) ?? .default
        providers = (try? c.decode([ProviderAccount].self, forKey: .providers)) ?? []
        logicalModels = (try? c.decode([LogicalModel].self, forKey: .logicalModels)) ?? []
        health = (try? c.decode(HealthSettings.self, forKey: .health)) ?? .default
        logging = (try? c.decode(LoggingSettings.self, forKey: .logging)) ?? .default
        app = (try? c.decode(AppSettings.self, forKey: .app)) ?? .default
        pricingOverrides = (try? c.decode([String: Pricing].self, forKey: .pricingOverrides)) ?? [:]
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
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
        providers.flatMap { $0.auth.secretRefs } + [gateway.localKeyRef]
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
                timeouts: TimeoutConfig(overallSeconds: 300, perAttemptSeconds: 180, firstTokenSeconds: 60),
                requiredCapabilities: [.tools]),
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

        // Future migrations go here, each bumping `version` by one, e.g.:
        //
        // if version == 1 {
        //     rawObject["logicalModels"] = ...rewrite...
        //     version = 2
        //     notes.append("Migrated logical models to schema 2")
        // }

        if version > DerbyConfig.currentSchemaVersion {
            notes.append("Configuration was written by a newer version of Derby (schema \(version)); unknown fields were preserved where possible.")
            version = DerbyConfig.currentSchemaVersion
        }
        rawObject["schemaVersion"] = version
        return notes
    }
}
