import Foundation

/// Holds the authoritative configuration and the derived, immutable snapshot
/// the data plane reads. Config mutations happen here and nowhere else; the
/// request path only ever *reads* a versioned snapshot.
public actor ControlPlaneState {
    private var config: DerbyConfig
    private var baseSnapshot: RoutingSnapshot
    private var version: UInt64 = 1
    /// Per-logical-model rotation counters for round-robin routing.
    private var cursors: [String: Int] = [:]

    public init(config: DerbyConfig) {
        self.config = config
        self.baseSnapshot = RoutingSnapshot.build(config: config, health: [:], version: 1)
    }

    public func currentConfig() -> DerbyConfig { config }
    public func currentVersion() -> UInt64 { version }

    public func setConfig(_ newConfig: DerbyConfig) {
        config = newConfig
        version &+= 1
        baseSnapshot = RoutingSnapshot.build(config: newConfig, health: [:], version: version)
    }

    /// Combines the cached config-derived snapshot with live health. Cheap: the
    /// expensive part (resolving targets) is done once per config change.
    public func snapshot(health: [TargetKey: TargetHealth]) -> RoutingSnapshot {
        var s = baseSnapshot
        s.health = health
        return s
    }

    public func nextCursor(for logicalModel: String) -> Int {
        let key = logicalModel.lowercased()
        let value = cursors[key, default: 0]
        cursors[key] = value &+ 1
        return value
    }
}
