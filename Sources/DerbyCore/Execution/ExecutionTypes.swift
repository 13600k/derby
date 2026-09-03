import Foundation

public struct RequestMeta: Sendable {
    public var requestID: String
    public var clientName: String
    public var dialect: APIDialect
    public var promptLogging: PromptLoggingMode
    public var promptExcerpt: String?

    public init(requestID: String = IDGenerator.requestID(), clientName: String = "unknown",
                dialect: APIDialect = .chatCompletions, promptLogging: PromptLoggingMode = .metadataOnly,
                promptExcerpt: String? = nil) {
        self.requestID = requestID
        self.clientName = clientName
        self.dialect = dialect
        self.promptLogging = promptLogging
        self.promptExcerpt = promptExcerpt
    }
}

public struct ExecutionOutcome: Sendable {
    public var response: CanonicalResponse
    public var record: RequestRecord
    public var target: ResolvedTarget
}

public struct EmbeddingOutcome: Sendable {
    public var response: CanonicalEmbeddingResponse
    public var record: RequestRecord
    public var target: ResolvedTarget
}

public enum ExecutionStreamEvent: Sendable {
    /// A target has been selected and is now producing.
    case attemptStarted(target: ResolvedTarget, attemptIndex: Int)
    case canonical(CanonicalStreamEvent)
    /// Terminal success. Always the last event.
    case finished(RequestRecord)
    /// Terminal failure *after* content already reached the client, so the API
    /// layer must end the stream rather than return an HTTP error.
    case failed(DerbyError, RequestRecord)
}

/// Streaming failover rules, stated explicitly because "resume a half-sent
/// stream" is not something Derby will pretend to do.
public enum StreamingSemantics {
    /// Before any byte of generated content has reached the client, a failed
    /// attempt is invisible: Derby transparently fails over and the client sees
    /// one clean stream from whichever target succeeds.
    public static let transparentBeforeFirstContent = true

    /// After content has been delivered, Derby never switches providers. The
    /// partial answer stands and the stream terminates with an error event, so
    /// the client is never handed two different models' text spliced together.
    public static let failoverAfterFirstContent = false

    public static let explanation = """
    Derby fails over transparently only until the first content token reaches \
    the client. Once the client has seen output, switching providers would \
    splice two different completions together, so Derby ends the stream with an \
    error event instead and records a mid-stream failure in request history.
    """
}
