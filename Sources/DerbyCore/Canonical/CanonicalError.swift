import Foundation

/// Derby's normalized failure taxonomy. Every provider error is classified into
/// exactly one of these, and routing/retry behaviour keys off the kind — never
/// off a provider-specific status code.
public enum FailureKind: String, Codable, Sendable, CaseIterable, Hashable {
    case transient = "TRANSIENT"
    case rateLimit = "RATE_LIMIT"
    case timeout = "TIMEOUT"
    case providerDown = "PROVIDER_DOWN"
    case authentication = "AUTHENTICATION"
    case invalidRequest = "INVALID_REQUEST"
    case contextOverflow = "CONTEXT_OVERFLOW"
    case contentPolicy = "CONTENT_POLICY"
    case capabilityMismatch = "CAPABILITY_MISMATCH"
    case modelUnavailable = "MODEL_UNAVAILABLE"
    case quotaExhausted = "QUOTA_EXHAUSTED"
    case clientCancelled = "CLIENT_CANCELLED"
    case unknown = "UNKNOWN"

    /// Default disposition. `FailurePolicy` in the control plane can override.
    public var defaultDisposition: FailureDisposition {
        switch self {
        case .transient, .timeout, .providerDown: return .retryThenFailover
        case .rateLimit, .quotaExhausted, .modelUnavailable: return .failover
        case .contextOverflow: return .failoverToLargerContext
        case .capabilityMismatch: return .failover
        case .authentication: return .failoverAndMarkUnhealthy
        case .invalidRequest, .contentPolicy: return .returnToClient
        case .clientCancelled: return .abort
        case .unknown: return .failover
        }
    }

    /// Whether this failure should count against the target's circuit breaker.
    public var countsAgainstHealth: Bool {
        switch self {
        case .invalidRequest, .contentPolicy, .clientCancelled, .capabilityMismatch: return false
        default: return true
        }
    }

    public var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public enum FailureDisposition: String, Codable, Sendable, CaseIterable {
    /// Retry the same target (subject to retry budget), then move on.
    case retryThenFailover = "retry_then_failover"
    /// Do not retry the same target; go straight to the next one.
    case failover
    /// Prefer the next target with a strictly larger context window.
    case failoverToLargerContext = "failover_to_larger_context"
    /// Fail over and open the target's circuit / flag a config problem.
    case failoverAndMarkUnhealthy = "failover_and_mark_unhealthy"
    /// The request itself is bad; surface the error verbatim.
    case returnToClient = "return_to_client"
    /// Stop everything immediately.
    case abort

    public var allowsRetry: Bool { self == .retryThenFailover }
    public var allowsFailover: Bool {
        switch self {
        case .retryThenFailover, .failover, .failoverToLargerContext, .failoverAndMarkUnhealthy: return true
        case .returnToClient, .abort: return false
        }
    }
    public var displayName: String {
        switch self {
        case .retryThenFailover: return "Retry, then fail over"
        case .failover: return "Fail over immediately"
        case .failoverToLargerContext: return "Fail over to larger context"
        case .failoverAndMarkUnhealthy: return "Fail over and mark unhealthy"
        case .returnToClient: return "Return error to client"
        case .abort: return "Abort request"
        }
    }
}

/// A normalized error. Carries enough provider detail for the request inspector
/// without leaking credentials.
public struct DerbyError: Error, Codable, Sendable {
    public var kind: FailureKind
    public var message: String
    public var providerStatus: Int?
    public var providerCode: String?
    /// Seconds the provider asked us to wait, from Retry-After or equivalent.
    public var retryAfter: Double?
    /// Redacted provider body excerpt, for debugging.
    public var detail: String?

    public init(kind: FailureKind, message: String, providerStatus: Int? = nil,
                providerCode: String? = nil, retryAfter: Double? = nil, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.providerStatus = providerStatus
        self.providerCode = providerCode
        self.retryAfter = retryAfter
        self.detail = detail
    }

    public static func cancelled(_ msg: String = "Client cancelled the request") -> DerbyError {
        DerbyError(kind: .clientCancelled, message: msg)
    }
    public static func invalid(_ msg: String) -> DerbyError {
        DerbyError(kind: .invalidRequest, message: msg, providerStatus: 400)
    }
    public static func timeout(_ msg: String) -> DerbyError {
        DerbyError(kind: .timeout, message: msg)
    }

    /// HTTP status Derby should return to the client for this error.
    public var clientHTTPStatus: Int {
        switch kind {
        case .invalidRequest: return 400
        case .authentication: return 401
        case .contentPolicy: return 403
        case .rateLimit, .quotaExhausted: return 429
        case .contextOverflow: return 400
        case .capabilityMismatch, .modelUnavailable: return 404
        case .timeout: return 504
        case .clientCancelled: return 499
        case .providerDown, .transient: return 502
        case .unknown: return 500
        }
    }

    /// OpenAI-compatible error `type` string.
    public var openAIErrorType: String {
        switch kind {
        case .invalidRequest, .contextOverflow: return "invalid_request_error"
        case .authentication: return "authentication_error"
        case .rateLimit, .quotaExhausted: return "rate_limit_error"
        case .contentPolicy: return "content_policy_violation"
        case .modelUnavailable, .capabilityMismatch: return "model_not_found"
        default: return "api_error"
        }
    }
}
