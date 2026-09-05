import Foundation
import os

/// Lightweight logging for code paths that have no `TelemetrySink` to hand —
/// credential handling and subprocess management both run beneath the executor.
///
/// Writes to the unified log *and* to a file under the support directory. The
/// unified log is not reliably readable for an ad-hoc-signed app, which is
/// exactly the build a user runs locally, so a plain file is what makes these
/// diagnosable. Everything is redacted on the way out.
public enum DerbyLog {
    private static let log = Logger(subsystem: "com.derby.gateway", category: "derby")
    private static let queue = DispatchQueue(label: "com.derby.log")
    private static let maxBytes = 512 * 1024

    public static var fileURL: URL { AppPaths.logDirectory.appendingPathComponent("derby.log") }

    public static func warn(_ category: String, _ message: String) {
        emit("WARN", category, message)
    }
    public static func info(_ category: String, _ message: String) {
        emit("INFO", category, message)
    }

    private static func emit(_ level: String, _ category: String, _ message: String) {
        let clean = SecretRedactor.redact(message)
        if level == "WARN" {
            log.warning("[\(category, privacy: .public)] \(clean, privacy: .public)")
        } else {
            log.info("[\(category, privacy: .public)] \(clean, privacy: .public)")
        }
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) [\(level)] \(category): \(clean)\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let url = fileURL
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Keep it bounded; a gateway can be long-lived.
            if (try? handle.seekToEnd()).map({ $0 > UInt64(maxBytes) }) == true {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Most recent lines, for the diagnostics export and the Logs screen.
    public static func tail(_ lines: Int = 200) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
