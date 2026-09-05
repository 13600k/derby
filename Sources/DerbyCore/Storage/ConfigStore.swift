import Foundation

public enum ConfigStoreError: LocalizedError {
    case unreadable(String)
    case unwritable(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let m): return "Could not read Derby configuration: \(m)"
        case .unwritable(let m): return "Could not save Derby configuration: \(m)"
        }
    }
}

/// Loads and atomically persists `DerbyConfig`. Migration runs on the raw JSON
/// before decoding, and the previous document is kept as a backup whenever the
/// schema version changes so a downgrade is always possible.
public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public private(set) var migrationNotes: [String] = []
    /// Set when `load` upgraded the document, so the caller can persist the
    /// result once instead of migrating (and re-warning) on every launch.
    public private(set) var didUpgradeSchema = false

    public init(url: URL = AppPaths.configFile) {
        self.url = url
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Loads config, seeding a fresh one on first run. Never throws for a
    /// corrupt file: it moves the bad file aside and starts clean, because a
    /// gateway that will not launch is worse than one that lost its settings.
    public func load() -> (config: DerbyConfig, isFirstRun: Bool, warnings: [String]) {
        lock.lock(); defer { lock.unlock() }
        var warnings: [String] = []
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (.seeded(), true, [])
        }
        do {
            let data = try Data(contentsOf: url)
            guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigStoreError.unreadable("root is not an object")
            }
            let previousVersion = (obj["schemaVersion"] as? Int) ?? 1
            let notes = ConfigMigrator.migrate(rawObject: &obj)
            migrationNotes = notes
            warnings.append(contentsOf: notes)
            let newVersion = (obj["schemaVersion"] as? Int) ?? previousVersion
            didUpgradeSchema = newVersion > previousVersion
            if newVersion != previousVersion {
                try? backup(data, tag: "schema\(previousVersion)")
            }
            let migrated = try JSONSerialization.data(withJSONObject: obj)
            let config = try Self.decoder.decode(DerbyConfig.self, from: migrated)
            if !config.decodeFailures.isEmpty {
                // Keep a copy before anything can save over the parts that were
                // dropped, and say so loudly rather than losing them quietly.
                try? backup(data, tag: "partial-decode")
                for failure in config.decodeFailures {
                    warnings.append("Part of the configuration could not be read and was reset (\(failure)). The previous file was copied to Backups.")
                }
            }
            return (config, false, warnings)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let moved = AppPaths.backupDirectory.appendingPathComponent("config.broken-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: moved)
            warnings.append("Existing configuration could not be read (\(error.localizedDescription)). It was moved to \(moved.lastPathComponent) and Derby started with defaults.")
            return (.seeded(), true, warnings)
        }
    }

    public func save(_ config: DerbyConfig) throws {
        lock.lock(); defer { lock.unlock() }
        var c = config
        c.updatedAt = Date()
        c.schemaVersion = DerbyConfig.currentSchemaVersion
        do {
            let data = try Self.encoder.encode(c)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            throw ConfigStoreError.unwritable(error.localizedDescription)
        }
    }

    private func backup(_ data: Data, tag: String) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = AppPaths.backupDirectory.appendingPathComponent("config-\(tag)-\(stamp).json")
        try data.write(to: dest)
    }

    // MARK: - Export / import

    /// Exports configuration. Secrets are never included; the export records
    /// which accounts *need* a credential so the import can prompt for them.
    public static func export(_ config: DerbyConfig, includeSecretPlaceholders: Bool = true) throws -> Data {
        var c = config
        if includeSecretPlaceholders {
            c.providers = c.providers.map { p in
                var p = p
                p.notes = p.notes
                return p
            }
        }
        var obj = try JSONSerialization.jsonObject(with: encoder.encode(c)) as? [String: Any] ?? [:]
        obj["_derbyExport"] = ["version": DerbyConfig.currentSchemaVersion,
                               "exportedAt": ISO8601DateFormatter().string(from: Date()),
                               "containsSecrets": false]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    public static func importConfig(from data: Data) throws -> (config: DerbyConfig, warnings: [String]) {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigStoreError.unreadable("root is not an object")
        }
        obj.removeValue(forKey: "_derbyExport")
        let notes = ConfigMigrator.migrate(rawObject: &obj)
        let migrated = try JSONSerialization.data(withJSONObject: obj)
        let config = try decoder.decode(DerbyConfig.self, from: migrated)
        var warnings = notes
        let needing = config.providers.filter { !$0.auth.secretRefs.isEmpty }
        if !needing.isEmpty {
            warnings.append("\(needing.count) provider\(needing.count == 1 ? "" : "s") need credentials re-entered: \(needing.map(\.name).joined(separator: ", ")).")
        }
        return (config, warnings)
    }
}
