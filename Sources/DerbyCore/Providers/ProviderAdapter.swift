import Foundation

/// Everything an adapter needs to perform one call. Adapters are stateless
/// values; all per-account state arrives here.
public struct ProviderContext: Sendable {
    public let account: ProviderAccount
    public let transport: any HTTPTransport
    public let secrets: any SecretStore
    public let credentials: CredentialCache
    /// Deadline for this attempt, in monotonic seconds. Adapters pass it to the
    /// transport so a slow provider cannot outlive the request budget.
    public let attemptTimeout: Double

    public init(account: ProviderAccount, transport: any HTTPTransport,
                secrets: any SecretStore, credentials: CredentialCache,
                attemptTimeout: Double = 120) {
        self.account = account
        self.transport = transport
        self.secrets = secrets
        self.credentials = credentials
        self.attemptTimeout = attemptTimeout
    }

    public func with(timeout: Double) -> ProviderContext {
        ProviderContext(account: account, transport: transport, secrets: secrets,
                        credentials: credentials, attemptTimeout: timeout)
    }
}

/// The result of resolving an account's `AuthConfig` into wire material.
public struct ResolvedAuth: Sendable {
    public var headers: [String: String]
    public var queryItems: [String: String]
    /// Some credentials carry their own API host (e.g. Qwen's resource_url).
    public var baseURLOverride: String?
    public init(headers: [String: String] = [:], queryItems: [String: String] = [:],
                baseURLOverride: String? = nil) {
        self.headers = headers; self.queryItems = queryItems; self.baseURLOverride = baseURLOverride
    }
}

public struct DiscoveredModel: Sendable, Hashable {
    public var id: String
    public var displayName: String?
    public var capabilities: ModelCapabilities?
    public init(id: String, displayName: String? = nil, capabilities: ModelCapabilities? = nil) {
        self.id = id; self.displayName = displayName; self.capabilities = capabilities
    }
}

public struct ConnectionTestResult: Sendable {
    public var ok: Bool
    public var headline: String
    public var details: [String]
    public var latencyMs: Int?
    public var discovered: [DiscoveredModel]
    public var error: DerbyError?

    public init(ok: Bool, headline: String, details: [String] = [], latencyMs: Int? = nil,
                discovered: [DiscoveredModel] = [], error: DerbyError? = nil) {
        self.ok = ok; self.headline = headline; self.details = details
        self.latencyMs = latencyMs; self.discovered = discovered; self.error = error
    }

    public static func failure(_ error: DerbyError, headline: String? = nil) -> ConnectionTestResult {
        var details: [String] = []
        if let s = error.providerStatus { details.append("Provider returned HTTP \(s).") }
        if let c = error.providerCode { details.append("Error code: \(c)") }
        if let d = error.detail, !d.isEmpty { details.append(d) }
        return ConnectionTestResult(ok: false,
                                    headline: headline ?? error.kind.displayName,
                                    details: details.isEmpty ? [error.message] : [error.message] + details,
                                    error: error)
    }
}

/// The single seam between Derby and any AI provider. Nothing outside this
/// protocol's implementations may know which provider it is talking to.
public protocol ProviderAdapter: Sendable {
    var family: AdapterFamily { get }

    /// Resolve credentials into headers/query for the account.
    func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth

    /// Ask the provider what models exist. Returns [] when unsupported.
    func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel]

    /// Adapter's opinion of a model's capabilities, before user overrides.
    func capabilities(model: String, ctx: ProviderContext) -> ModelCapabilities

    func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse

    func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error>

    func embed(_ request: CanonicalEmbeddingRequest, model: String, ctx: ProviderContext) async throws
        -> CanonicalEmbeddingResponse

    /// A cheap liveness/credential check used by the UI and the health subsystem.
    func healthCheck(_ ctx: ProviderContext) async -> ConnectionTestResult

    /// Normalize a provider failure into Derby's taxonomy.
    func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError

    /// Extract rate-limit state from response headers, when the provider sends it.
    func rateLimitSnapshot(from headers: [String: String]) -> RateLimitSnapshot?
}

// MARK: - Shared defaults

extension ProviderAdapter {
    public func capabilities(model: String, ctx: ProviderContext) -> ModelCapabilities {
        ModelCatalog.metadata(for: model, kind: ctx.account.kind).capabilities
    }

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        ModelCatalog.presetModels(for: ctx.account.kind).map { DiscoveredModel(id: $0) }
    }

    public func embed(_ request: CanonicalEmbeddingRequest, model: String, ctx: ProviderContext) async throws
        -> CanonicalEmbeddingResponse {
        throw DerbyError(kind: .capabilityMismatch,
                         message: "\(ctx.account.kind.displayName) does not expose an embeddings API through Derby.")
    }

    public func rateLimitSnapshot(from headers: [String: String]) -> RateLimitSnapshot? {
        RateLimitSnapshot.parseStandardHeaders(headers)
    }

    /// Default health check: list models, which exercises both connectivity and
    /// credentials without spending tokens.
    public func healthCheck(_ ctx: ProviderContext) async -> ConnectionTestResult {
        let t0 = Clock.monotonic
        do {
            let models = try await listModels(ctx)
            let ms = Int((Clock.monotonic - t0) * 1000)
            var details = ["\(models.count) model\(models.count == 1 ? "" : "s") discovered.",
                           "Latency: \(ms) ms"]
            if models.isEmpty {
                details = ["Connected, but the endpoint returned no models.",
                           "Add model names manually if this server does not implement /v1/models.",
                           "Latency: \(ms) ms"]
            }
            return ConnectionTestResult(ok: true, headline: "Connected", details: details,
                                        latencyMs: ms, discovered: models)
        } catch let e as DerbyError {
            return .failure(e)
        } catch {
            return .failure(DerbyError(kind: .unknown, message: error.localizedDescription))
        }
    }

    // MARK: Helpers available to every adapter

    /// Builds a URL from the account base plus a path, merging query items.
    func url(_ ctx: ProviderContext, path: String, auth: ResolvedAuth,
             extraQuery: [String: String] = [:]) throws -> URL {
        let base = auth.baseURLOverride ?? ctx.account.baseURL
        guard !base.isEmpty else {
            throw DerbyError(kind: .invalidRequest,
                             message: "\(ctx.account.name) has no base URL configured.")
        }
        let joined = path.isEmpty ? base : base.trimmedTrailingSlash + "/" + path.trimmingLeadingSlash
        guard var comps = URLComponents(string: joined) else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid base URL: \(base)")
        }
        var items = comps.queryItems ?? []
        for (k, v) in auth.queryItems.merging(extraQuery, uniquingKeysWith: { _, b in b }) {
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items.isEmpty ? nil : items
        guard let u = comps.url else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid URL built from \(base)")
        }
        return u
    }

    func headers(_ ctx: ProviderContext, auth: ResolvedAuth, contentType: String = "application/json") -> [String: String] {
        var h = auth.headers
        h["content-type"] = contentType
        h["user-agent"] = "Derby/1.0 (macOS)"
        for (k, v) in ctx.account.extraHeaders where !k.isEmpty { h[k.lowercased()] = v }
        return h
    }

    /// Reads an API key, producing a clear configuration error when absent.
    func requireSecret(_ ref: SecretRef, ctx: ProviderContext, label: String) throws -> String {
        guard let v = ctx.secrets.get(ref), !v.isEmpty else {
            throw DerbyError(kind: .authentication,
                             message: "No \(label) saved for \(ctx.account.name). Add one in Providers.")
        }
        return v
    }
}

extension String {
    var trimmingLeadingSlash: String {
        var s = self
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }
}

/// Caches CLI-sourced OAuth credentials so the hot path does not re-read files,
/// and serializes refreshes so concurrent requests cannot rotate a token twice.
public actor CredentialCache {
    /// Identity of one credential store. Keying on the source alone would make
    /// two accounts of the same service — separate CLI homes, separate logins —
    /// silently share a single credential.
    private struct Key: Hashable {
        var source: CLICredentialSource
        var home: String?
    }
    private struct Entry {
        var credential: CLICredential
        var loadedAt: Double
    }
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<CLICredential, Error>] = [:]
    /// Re-read the CLI's file this often even when the token has not expired,
    /// so a re-login in the terminal is picked up promptly.
    private let rereadInterval: Double = 30

    public init() {}

    public func credential(for source: CLICredentialSource, allowRefresh: Bool,
                           home: URL? = nil) async throws -> CLICredential {
        let key = Key(source: source, home: home?.standardizedFileURL.path)
        if let existing = inFlight[key] { return try await existing.value }

        if let e = entries[key],
           Clock.monotonic - e.loadedAt < rereadInterval,
           !e.credential.isExpired() {
            return e.credential
        }

        let task = Task<CLICredential, Error> {
            var cred = try CLICredentialReader.read(source, home: home)
            if cred.isExpired() {
                guard allowRefresh else {
                    let where_ = home.map { " in \($0.path)" } ?? ""
                    throw DerbyError(kind: .authentication,
                                     message: "The \(source.displayName) session\(where_) has expired. Run `\(source.loginCommand)` in Terminal, or enable managed token refresh for this account.")
                }
                cred = try await CLICredentialReader.refresh(source, current: cred, home: home)
            }
            return cred
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let cred = try await task.value
        entries[key] = Entry(credential: cred, loadedAt: Clock.monotonic)
        return cred
    }

    /// Drops cached credentials, forcing the next request to re-read from disk.
    public func invalidate(_ source: CLICredentialSource? = nil) {
        if let source { entries = entries.filter { $0.key.source != source } } else { entries.removeAll() }
    }
}
