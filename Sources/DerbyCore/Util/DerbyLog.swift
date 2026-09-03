import Foundation
import os

/// Lightweight logging for code paths that have no `TelemetrySink` to hand
/// (credential handling runs beneath the executor). Everything is redacted.
public enum DerbyLog {
    private static let log = Logger(subsystem: "com.derby.gateway", category: "derby")

    public static func warn(_ category: String, _ message: String) {
        log.warning("[\(category, privacy: .public)] \(SecretRedactor.redact(message), privacy: .public)")
    }
    public static func info(_ category: String, _ message: String) {
        log.info("[\(category, privacy: .public)] \(SecretRedactor.redact(message), privacy: .public)")
    }
}
