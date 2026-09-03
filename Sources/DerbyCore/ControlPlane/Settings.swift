import Foundation

public struct GatewaySettings: Codable, Sendable, Hashable {
    public var port: Int
    /// Defaults to loopback. Binding elsewhere requires an explicit opt-in.
    public var bindAddress: String
    public var requireAPIKey: Bool
    /// Keychain reference for the generated local key.
    public var localKeyRef: SecretRef
    public var autoStart: Bool
    /// Allow non-loopback binds. Guard-railed in the UI with a warning.
    public var allowRemoteAccess: Bool
    public var maxConcurrentRequests: Int
    /// CORS allowlist; empty means echo the request origin for localhost only.
    public var allowedOrigins: [String]

    public init(port: Int = 8787, bindAddress: String = "127.0.0.1",
                requireAPIKey: Bool = true,
                localKeyRef: SecretRef = SecretRef(account: "gateway.localKey"),
                autoStart: Bool = true, allowRemoteAccess: Bool = false,
                maxConcurrentRequests: Int = 64,
                allowedOrigins: [String] = []) {
        self.port = port; self.bindAddress = bindAddress
        self.requireAPIKey = requireAPIKey; self.localKeyRef = localKeyRef
        self.autoStart = autoStart; self.allowRemoteAccess = allowRemoteAccess
        self.maxConcurrentRequests = maxConcurrentRequests
        self.allowedOrigins = allowedOrigins
    }
    public static let `default` = GatewaySettings()

    public var endpointURL: String {
        let host = bindAddress == "0.0.0.0" ? "127.0.0.1" : bindAddress
        return "http://\(host):\(port)/v1"
    }
}

/// How much of a request Derby keeps. Prompt bodies are off by default.
public enum PromptLoggingMode: String, Codable, Sendable, CaseIterable {
    case none
    case metadataOnly = "metadata_only"
    case truncated
    case full
    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .metadataOnly: return "Metadata only (default)"
        case .truncated: return "First 2 KB of prompt & response"
        case .full: return "Full prompt & response"
        }
    }
    public var storesContent: Bool { self == .truncated || self == .full }
    public var truncationLimit: Int? { self == .truncated ? 2048 : nil }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, warn, error
    private var order: Int { switch self { case .debug: 0; case .info: 1; case .warn: 2; case .error: 3 } }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.order < b.order }
    public var displayName: String { rawValue.capitalized }
}

public struct LoggingSettings: Codable, Sendable, Hashable {
    public var level: LogLevel
    public var promptLogging: PromptLoggingMode
    /// Days of request history to keep; 0 = forever.
    public var historyRetentionDays: Int
    public var maxHistoryRows: Int
    public var logRetentionDays: Int

    public init(level: LogLevel = .info, promptLogging: PromptLoggingMode = .metadataOnly,
                historyRetentionDays: Int = 30, maxHistoryRows: Int = 50_000,
                logRetentionDays: Int = 7) {
        self.level = level; self.promptLogging = promptLogging
        self.historyRetentionDays = historyRetentionDays
        self.maxHistoryRows = maxHistoryRows
        self.logRetentionDays = logRetentionDays
    }
    public static let `default` = LoggingSettings()
}

/// Thresholds for the health tracker and circuit breakers. Global, because they
/// describe how Derby measures targets rather than how it prefers them.
public struct HealthSettings: Codable, Sendable, Hashable {
    /// Size of the rolling window used for success/latency statistics.
    public var windowSize: Int
    /// Consecutive failures that trip a closed circuit open.
    public var failureThreshold: Int
    /// Error rate over the window that also trips the circuit (0–1).
    public var errorRateThreshold: Double
    /// Minimum samples before the error-rate rule can fire.
    public var minimumSamples: Int
    /// How long a circuit stays open before a probe is allowed.
    public var openDurationSeconds: Double
    /// Consecutive successes in half-open needed to close.
    public var halfOpenSuccessesToClose: Int
    /// Concurrent probes permitted while half-open.
    public var halfOpenMaxProbes: Int
    /// Error rate above which a target is DEGRADED but still usable (0–1).
    public var degradedErrorRate: Double
    /// Passive health checks only, unless this is on.
    public var activeProbesEnabled: Bool
    public var activeProbeIntervalSeconds: Double

    public init(windowSize: Int = 50, failureThreshold: Int = 4, errorRateThreshold: Double = 0.5,
                minimumSamples: Int = 5, openDurationSeconds: Double = 30,
                halfOpenSuccessesToClose: Int = 2, halfOpenMaxProbes: Int = 1,
                degradedErrorRate: Double = 0.2, activeProbesEnabled: Bool = false,
                activeProbeIntervalSeconds: Double = 300) {
        self.windowSize = windowSize; self.failureThreshold = failureThreshold
        self.errorRateThreshold = errorRateThreshold; self.minimumSamples = minimumSamples
        self.openDurationSeconds = openDurationSeconds
        self.halfOpenSuccessesToClose = halfOpenSuccessesToClose
        self.halfOpenMaxProbes = halfOpenMaxProbes
        self.degradedErrorRate = degradedErrorRate
        self.activeProbesEnabled = activeProbesEnabled
        self.activeProbeIntervalSeconds = activeProbeIntervalSeconds
    }
    public static let `default` = HealthSettings()
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var launchAtLogin: Bool
    public var showMenuBarExtra: Bool
    public var keepRunningWhenWindowClosed: Bool
    public var hasCompletedOnboarding: Bool
    public var checkForUpdates: Bool
    /// Offer to import models from local servers Derby detects.
    public var autoDiscoverLocalServers: Bool

    public init(launchAtLogin: Bool = false, showMenuBarExtra: Bool = true,
                keepRunningWhenWindowClosed: Bool = true,
                hasCompletedOnboarding: Bool = false,
                checkForUpdates: Bool = false,
                autoDiscoverLocalServers: Bool = true) {
        self.launchAtLogin = launchAtLogin
        self.showMenuBarExtra = showMenuBarExtra
        self.keepRunningWhenWindowClosed = keepRunningWhenWindowClosed
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.checkForUpdates = checkForUpdates
        self.autoDiscoverLocalServers = autoDiscoverLocalServers
    }
    public static let `default` = AppSettings()
}
