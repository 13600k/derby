import Foundation

/// A physical routing target with everything the router needs, pre-resolved.
public struct ResolvedTarget: Sendable, Identifiable {
    public var id: UUID { ref.id }
    public var ref: TargetRef
    public var key: TargetKey
    public var account: ProviderAccount
    public var model: PhysicalModel
    public var capabilities: ModelCapabilities
    public var pricing: Pricing?
    public var quality: Double
    /// Position in the logical model's target list; 0 is highest priority.
    public var order: Int
    /// Non-nil when the target exists in config but cannot be used. Kept (rather
    /// than dropped) so the router can explain why it was not considered.
    public var unavailableReason: String?

    public var providerName: String { account.name }
    public var modelID: String { model.modelID }
    public var label: String { "\(account.name) · \(model.label)" }
    public var isLocal: Bool { account.kind.isLocal }
    public var isSubscription: Bool { account.kind.isSubscription }
    /// Which weights this target serves, whoever serves them.
    public var lineage: ModelLineage { ModelLineage.parse(model.modelID, familyHint: model.profile?.family) }
    /// The account's concurrency ceiling, or a nominal one when it is unlimited.
    public var concurrencyCapacity: Int {
        let limit = account.rateLimits.maxConcurrentRequests
        return limit > 0 ? limit : 8
    }
}

public struct ResolvedLogicalModel: Sendable {
    public var definition: LogicalModel
    public var targets: [ResolvedTarget]
    public var name: String { definition.name }
}

/// The immutable view of configuration + health that the hot request path uses.
/// Rebuilt by the control plane whenever configuration or health changes;
/// requests capture it by reference so they never await a lock.
public struct RoutingSnapshot: Sendable {
    public var version: UInt64
    public var builtAt: Date
    public var logicalModels: [String: ResolvedLogicalModel]   // keyed by lowercased name
    public var accounts: [UUID: ProviderAccount]
    public var health: [TargetKey: TargetHealth]
    public var healthSettings: HealthSettings
    public var loggingSettings: LoggingSettings
    /// What each local server last reported as loaded.
    public var residency: [UUID: AccountResidency]
    /// In-flight and reserved requests per account, read with `health`.
    public var accountLoad: [UUID: HealthRegistry.AccountLoad] = [:]
    /// `HealthRegistry`'s load version when `health` was read, so a
    /// reservation can tell whether anything moved since.
    public var loadVersion: UInt64

    public init(version: UInt64 = 0, builtAt: Date = Date(),
                logicalModels: [String: ResolvedLogicalModel] = [:],
                accounts: [UUID: ProviderAccount] = [:],
                health: [TargetKey: TargetHealth] = [:],
                healthSettings: HealthSettings = .default,
                loggingSettings: LoggingSettings = .default,
                residency: [UUID: AccountResidency] = [:],
                loadVersion: UInt64 = 0) {
        self.version = version
        self.builtAt = builtAt
        self.logicalModels = logicalModels
        self.accounts = accounts
        self.health = health
        self.healthSettings = healthSettings
        self.loggingSettings = loggingSettings
        self.residency = residency
        self.loadVersion = loadVersion
    }

    /// Whether `target` can answer without loading its model first.
    public func warmth(for target: ResolvedTarget, now: Date = Date()) -> ModelWarmth {
        guard target.isLocal else { return .alwaysAvailable }
        if let report = residency[target.account.id], let loaded = report.loadedModels,
           now.timeIntervalSince(report.observedAt) <= ModelResidency.freshness {
            return loaded.contains(ModelResidency.normalize(target.modelID)) ? .loaded : .cold
        }
        if let last = health(for: target.key).lastSuccessAt,
           now.timeIntervalSince(last) <= ModelResidency.recentUseWindow {
            return .recentlyUsed
        }
        return .unknown
    }

    /// What the server behind `target` last said it was doing, while that is
    /// still recent enough to act on.
    public func occupancy(for target: ResolvedTarget, now: Date = Date()) -> ServerOccupancy? {
        guard let report = residency[target.account.id], let occupancy = report.occupancy,
              now.timeIntervalSince(report.observedAt) <= ModelResidency.freshness else { return nil }
        return occupancy
    }

    /// Share of the target's capacity already committed: requests Derby has in
    /// flight or about to start, or what the server itself reports — whichever
    /// is higher. Derby sees only its own traffic; a server sees everyone's.
    public func loadUtilization(for target: ResolvedTarget) -> Double {
        let load = accountLoad[target.account.id] ?? HealthRegistry.AccountLoad()
        let mine = Double(load.inFlight + load.reserved) / Double(target.concurrencyCapacity)
        guard let reported = occupancy(for: target)?.utilization else { return mine }
        return max(mine, reported)
    }

    public func logicalModel(named name: String) -> ResolvedLogicalModel? {
        logicalModels[name.lowercased()]
    }

    public var logicalModelNames: [String] {
        logicalModels.values.map(\.name).sorted()
    }

    public func health(for key: TargetKey) -> TargetHealth {
        health[key] ?? TargetHealth(key: key)
    }

    /// Builds a snapshot from configuration and current health.
    public static func build(config: DerbyConfig, health: [TargetKey: TargetHealth], version: UInt64) -> RoutingSnapshot {
        var accounts: [UUID: ProviderAccount] = [:]
        for p in config.providers { accounts[p.id] = p }

        var models: [String: ResolvedLogicalModel] = [:]
        for lm in config.logicalModels where lm.enabled {
            var targets: [ResolvedTarget] = []
            for (index, ref) in lm.targets.enumerated() {
                guard let account = accounts[ref.providerID] else { continue }
                guard let model = account.model(id: ref.modelUUID) else { continue }
                var unavailable: String?
                if !ref.enabled { unavailable = "target turned off in this logical model" }
                else if !account.enabled { unavailable = "provider \(account.name) is turned off" }
                else if !model.enabled { unavailable = "model turned off on \(account.name)" }

                let catalog = ModelCatalog.metadata(for: model.modelID, kind: account.kind)
                // Metadata is re-resolved on every snapshot, not frozen at the
                // moment a model was added, so an improved catalog corrects a
                // stored guess without the user re-running discovery.
                //
                //  * `.discovered` — the provider itself stated this; keep it and
                //    fill the gaps it left (discovery reports features but seldom
                //    a context window).
                //  * `.builtin` / `.unknown` — Derby guessed from a table. Re-derive:
                //    the table may since have learned the real numbers.
                var caps: ModelCapabilities
                switch model.capabilities.source {
                case .discovered, .userOverride:
                    caps = model.capabilities.completed(by: catalog.capabilities)
                case .builtin, .unknown:
                    caps = catalog.capabilities
                }
                caps = caps.overridden(by: model.capabilityOverrides)

                let overrideKey = "\(account.id.uuidString)/\(model.modelID)"
                var pricing = model.pricingOverride ?? catalog.pricing
                if let global = config.pricingOverrides[overrideKey] {
                    pricing = (pricing ?? Pricing()).merged(with: global)
                }
                if account.kind.isLocal || account.kind.isSubscription {
                    pricing = pricing ?? .free
                }

                targets.append(ResolvedTarget(
                    ref: ref,
                    key: TargetKey(providerID: account.id, modelID: model.modelID),
                    account: account,
                    model: model,
                    capabilities: caps,
                    pricing: pricing,
                    quality: ref.qualityOverride ?? model.qualityScore,
                    order: index,
                    unavailableReason: unavailable))
            }
            models[lm.name.lowercased()] = ResolvedLogicalModel(definition: lm, targets: targets)
        }
        return RoutingSnapshot(version: version, logicalModels: models, accounts: accounts,
                               health: health, healthSettings: config.health,
                               loggingSettings: config.logging)
    }
}
