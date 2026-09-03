import Foundation

public enum AppPaths {
    public static let bundleID = "com.derby.gateway"

    public static var supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Derby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var databaseFile: URL { supportDirectory.appendingPathComponent("derby.sqlite3") }
    public static var logDirectory: URL {
        let d = supportDirectory.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var backupDirectory: URL {
        let d = supportDirectory.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
