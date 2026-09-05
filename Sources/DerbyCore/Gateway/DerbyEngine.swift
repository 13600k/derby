import Foundation

public enum GatewayStatus: Sendable, Equatable {
    case stopped
    case starting
    case running(port: Int, since: Date)
    case failed(String)

    public var isRunning: Bool { if case .running = self { return true }; return false }
    public var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .failed: return "Failed"
        }
    }
    public var detail: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

/// The application-facing façade over the whole system. The UI talks only to
/// this; it owns lifecycle, persistence and the objects the request path needs.
public actor DerbyEngine {
    // These are all Sendable and safe to touch from any context, so they are
    // `nonisolated`: the UI reads them without hopping onto the engine actor.
    public nonisolated let configStore: ConfigStore
    public nonisolated let secrets: any SecretStore
    public nonisolated let telemetry: TelemetryStore
    public nonisolated let healthRegistry: HealthRegistry
    public nonisolated let credentials = CredentialCache()
    public nonisolated let transport: any HTTPTransport
    private let adapters: AdapterRegistry

    private let state: ControlPlaneState
    private var server = HTTPServer()
    private var executor: Executor!
    private(set) public var status: GatewayStatus = .stopped
    private(set) public var startupWarnings: [String] = []
    private(set) public var isFirstRun: Bool
    /// Set when routing is paused from the menu bar: the gateway keeps
    /// listening but rejects inference so nothing is sent to providers.
    private var routingPaused = false
    /// Resolved once at start-up so the request path never touches the Keychain.
    private var cachedLocalKey: String?

    public init(configStore: ConfigStore = ConfigStore(),
                secrets: (any SecretStore)? = nil,
                transport: any HTTPTransport = URLSessionTransport.shared,
                adapters: AdapterRegistry = .default,
                telemetry: TelemetryStore? = nil) {
        self.configStore = configStore
        self.secrets = secrets ?? KeychainSecretStore()
        self.transport = transport
        self.adapters = adapters

        let loaded = configStore.load()
        self.isFirstRun = loaded.isFirstRun
        self.startupWarnings = loaded.warnings
        var config = loaded.config

        if loaded.isFirstRun { config.app.hasCompletedOnboarding = false }

        self.state = ControlPlaneState(config: config)
        self.telemetry = telemetry ?? TelemetryStore(settings: config.logging)
        self.healthRegistry = HealthRegistry(settings: config.health)
    }

    public func bootstrap() async {
        let config = await state.currentConfig()
        // Clients need nothing but the port by default, so the Keychain is not
        // touched at all unless the local key is switched on. When it is,
        // reading the Keychain can raise a system authorization dialog that
        // blocks until the user answers it — doing it here rather than in
        // `init` keeps it off the launch path, so the window is already on
        // screen when the prompt appears.
        if config.gateway.requireAPIKey { await ensureLocalAPIKey() }
        do { try await telemetry.open() }
        catch { startupWarnings.append("Request history is unavailable: \(error.localizedDescription)") }
        await telemetry.update(settings: config.logging)
        await healthRegistry.update(settings: config.health)
        await healthRegistry.update(accountLimits: accountLimits(config))
        executor = Executor(registry: adapters, transport: transport, secrets: secrets,
                            credentials: credentials, health: healthRegistry, telemetry: telemetry)
        await telemetry.pruneNow()
        // Write the seeded configuration out immediately, so a first-run install
        // has a config file on disk even if the user never changes anything. A
        // migrated document is written back for the same reason: otherwise it is
        // upgraded again — and its notes shown again — on every launch.
        if isFirstRun || configStore.didUpgradeSchema {
            do { try configStore.save(config) }
            catch { startupWarnings.append("Could not write the initial configuration: \(error.localizedDescription)") }
        }
        if config.gateway.autoStart {
            do { try await startGateway() }
            catch { status = .failed(error.localizedDescription) }
        }
    }

    /// Loads (or creates) the gateway's local API key.
    ///
    /// Keychain access can raise a system authorization dialog, and the
    /// underlying call blocks until the user answers it. That happens on a
    /// detached thread *and* under a deadline, so an unanswered dialog delays
    /// nothing: Derby comes up, the gateway starts, and requests fail closed
    /// with an actionable message until the key becomes readable.
    private func ensureLocalAPIKey() async {
        let ref = await state.currentConfig().gateway.localKeyRef
        let store = secrets
        let channel = AsyncEventChannel<String?>()

        Task.detached(priority: .userInitiated) {
            if let existing = store.get(ref), !existing.isEmpty {
                await channel.push(existing)
            } else {
                let key = DerbyEngine.generateLocalKey()
                do {
                    try store.set(key, for: ref)
                    await channel.push(key)
                } catch {
                    await channel.push(nil)
                }
            }
            await channel.finish()
        }

        let resolved = try? await channel.next(timeout: 6,
                                               timeoutMessage: "Keychain access timed out")
        if let key = resolved ?? nil, !key.isEmpty {
            cachedLocalKey = key
        } else {
            cachedLocalKey = nil
            startupWarnings.append("Derby could not read its local API key from the Keychain — macOS may be waiting for you to allow access. Until then the gateway refuses requests. Allow access and restart the gateway, or turn off \u{201C}Require the local API key\u{201D} in Settings.")
        }
    }

    private func accountLimits(_ config: DerbyConfig) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0.rateLimits.maxConcurrentRequests) })
    }

    public static func generateLocalKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytesShim(&bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "derby-\(hex)"
    }

    // MARK: - Config access

    public func config() async -> DerbyConfig { await state.currentConfig() }

    /// Applies and persists a configuration change, then rebuilds the snapshot
    /// the request path reads. Running requests keep the snapshot they started
    /// with, so a mid-flight config edit can never corrupt them.
    @discardableResult
    public func update(_ mutate: @Sendable (inout DerbyConfig) -> Void) async -> Result<DerbyConfig, Error> {
        var config = await state.currentConfig()
        mutate(&config)
        await state.setConfig(config)
        await healthRegistry.update(settings: config.health)
        await healthRegistry.update(accountLimits: accountLimits(config))
        await telemetry.update(settings: config.logging)
        secrets.prune(keeping: config.allSecretRefs)
        do {
            try configStore.save(config)
            return .success(config)
        } catch {
            return .failure(error)
        }
    }

    public func snapshot() async -> RoutingSnapshot {
        let h = await healthRegistry.snapshot()
        return await state.snapshot(health: h)
    }

    /// The local key, generating and storing one on first use. Only call this
    /// when the key is actually wanted — it can raise a Keychain dialog, and the
    /// default gateway never needs a key at all.
    public func localAPIKey() async -> String {
        if let cachedLocalKey { return cachedLocalKey }
        await ensureLocalAPIKey()
        return cachedLocalKey ?? ""
    }

    public func regenerateLocalKey() async -> String {
        let key = DerbyEngine.generateLocalKey()
        let config = await state.currentConfig()
        try? secrets.set(key, for: config.gateway.localKeyRef)
        cachedLocalKey = key
        return key
    }

    // MARK: - Gateway lifecycle

    public func startGateway() async throws {
        guard !status.isRunning else { return }
        status = .starting
        let config = await state.currentConfig()
        // The toggle can be flipped on long after bootstrap, which is the only
        // moment the key has to exist.
        if config.gateway.requireAPIKey && cachedLocalKey == nil { await ensureLocalAPIKey() }
        if executor == nil {
            executor = Executor(registry: adapters, transport: transport, secrets: secrets,
                                credentials: credentials, health: healthRegistry, telemetry: telemetry)
        }
        let handler = GatewayHandler(state: state, health: healthRegistry, telemetry: telemetry,
                                     executor: executor, secrets: secrets,
                                     gatewaySettings: config.gateway,
                                     localAPIKey: cachedLocalKey,
                                     promptLogging: config.logging.promptLogging)
        let paused = { [weak self] () async -> Bool in
            guard let self else { return false }
            return await self.routingPaused
        }
        do {
            try await server.start(host: config.gateway.bindAddress,
                                   port: config.gateway.port,
                                   maxConcurrentRequests: config.gateway.maxConcurrentRequests) { request in
                if await paused(), request.head.method == "POST" {
                    return .json(503, OpenAIResponseWriter.errorObject(
                        DerbyError(kind: .providerDown,
                                   message: "Derby routing is paused. Resume it from the Derby menu bar item.",
                                   providerStatus: 503),
                        requestID: "-"))
                }
                return await handler.handle(request)
            }
            let port = await server.boundPort
            status = .running(port: port, since: Date())
            await telemetry.log(LogEntry(level: .info, category: "gateway",
                                         message: "Gateway listening on http://\(config.gateway.bindAddress):\(port)/v1"))
        } catch {
            status = .failed(error.localizedDescription)
            await telemetry.log(LogEntry(level: .error, category: "gateway",
                                         message: "Failed to start: \(error.localizedDescription)"))
            throw error
        }
    }

    public func stopGateway() async {
        await server.stop()
        status = .stopped
        await telemetry.log(LogEntry(level: .info, category: "gateway", message: "Gateway stopped."))
    }

    public func restartGateway() async throws {
        await stopGateway()
        try await startGateway()
    }

    public func setRoutingPaused(_ paused: Bool) {
        routingPaused = paused
    }
    public func isRoutingPaused() -> Bool { routingPaused }

    public var endpointURL: String {
        get async {
            let config = await state.currentConfig()
            if case .running(let port, _) = status {
                var g = config.gateway
                g.port = port
                return g.endpointURL
            }
            return config.gateway.endpointURL
        }
    }

    // MARK: - Provider operations

    private func context(for account: ProviderAccount, timeout: Double = 30,
                         modelID: String? = nil) -> ProviderContext {
        // Resolve the model's metadata when one is named, so a probe shapes its
        // request the same way the executor would — including omitting
        // parameters the model rejects.
        let capabilities = modelID.map { id -> ModelCapabilities in
            let stored = account.model(modelID: id)
            let catalog = ModelCatalog.metadata(for: id, kind: account.kind).capabilities
            guard let stored else { return catalog }
            let base = stored.capabilities.source == .discovered || stored.capabilities.source == .userOverride
                ? stored.capabilities.completed(by: catalog)
                : catalog
            return base.overridden(by: stored.capabilityOverrides)
        }
        return ProviderContext(account: account, transport: transport, secrets: secrets,
                               credentials: credentials, attemptTimeout: timeout,
                               modelCapabilities: capabilities)
    }

    public func testConnection(_ account: ProviderAccount) async -> ConnectionTestResult {
        await credentials.invalidate()
        let adapter = adapters.adapter(for: account.kind)
        let result = await adapter.healthCheck(context(for: account))
        await telemetry.log(LogEntry(level: result.ok ? .info : .warn, category: "provider",
                                     message: "Connection test for \(account.name): \(result.headline)"))
        return result
    }

    public func discoverModels(_ account: ProviderAccount) async throws -> [DiscoveredModel] {
        let adapter = adapters.adapter(for: account.kind)
        return try await adapter.listModels(context(for: account))
    }

    /// Sends a single cheap completion to verify a specific model really works.
    public func probeModel(account: ProviderAccount, modelID: String) async -> ConnectionTestResult {
        let adapter = adapters.adapter(for: account.kind)
        var request = CanonicalRequest(requestedModel: modelID)
        request.messages = [.user("Reply with the single word: ok")]
        request.maxOutputTokens = 16
        // Deliberately set: the adapter drops it for a model that rejects
        // sampling parameters, so the probe also exercises that shaping.
        request.temperature = 0
        let ctx = context(for: account, timeout: 60, modelID: modelID)
        let t0 = Clock.monotonic
        do {
            let response = try await adapter.execute(request, model: modelID, ctx: ctx)
            let ms = Int((Clock.monotonic - t0) * 1000)
            return ConnectionTestResult(
                ok: true, headline: "Model responded",
                details: ["Replied: \(response.message.joinedText.prefix(60))",
                          "Latency: \(ms) ms",
                          "Tokens: \(response.usage.inputTokens) in / \(response.usage.outputTokens) out"],
                latencyMs: ms)
        } catch let e as DerbyError {
            return .failure(e)
        } catch {
            return .failure(DerbyError(kind: .unknown, message: error.localizedDescription))
        }
    }

    // MARK: - Routing simulation

    public struct SimulationInput: Sendable {
        public var logicalModel: String
        public var needsVision: Bool
        public var needsTools: Bool
        public var needsJSONSchema: Bool
        public var needsReasoning: Bool
        public var streaming: Bool
        public var contextTokens: Int
        public var maxOutputTokens: Int?
        public init(logicalModel: String, needsVision: Bool = false, needsTools: Bool = false,
                    needsJSONSchema: Bool = false, needsReasoning: Bool = false, streaming: Bool = true,
                    contextTokens: Int = 4000, maxOutputTokens: Int? = nil) {
            self.logicalModel = logicalModel
            self.needsVision = needsVision
            self.needsTools = needsTools
            self.needsJSONSchema = needsJSONSchema
            self.needsReasoning = needsReasoning
            self.streaming = streaming
            self.contextTokens = contextTokens
            self.maxOutputTokens = maxOutputTokens
        }

        var requirements: CapabilityRequirements {
            var flags: CapabilityFlags = [.text]
            if needsVision { flags.insert(.vision) }
            if needsTools { flags.insert(.tools) }
            if needsJSONSchema { flags.insert(.jsonSchema) }
            if needsReasoning { flags.insert(.reasoning) }
            if streaming { flags.insert(.streaming) }
            return CapabilityRequirements(required: flags,
                                          minContextTokens: contextTokens + (maxOutputTokens ?? 0),
                                          minOutputTokens: maxOutputTokens)
        }
    }

    public func simulate(_ input: SimulationInput) async -> Result<RoutingDecision, DerbyError> {
        let snap = await snapshot()
        let request = RoutingRequest(logicalModelName: input.logicalModel,
                                     requirements: input.requirements,
                                     promptTokens: input.contextTokens,
                                     maxOutputTokens: input.maxOutputTokens,
                                     isStreaming: input.streaming)
        do {
            // Fixed seed keeps repeated simulations comparable.
            return .success(try Router().route(request, snapshot: snap, roundRobinCursor: 0, randomSeed: 42))
        } catch let e as DerbyError {
            return .failure(e)
        } catch {
            return .failure(DerbyError(kind: .unknown, message: error.localizedDescription))
        }
    }

    // MARK: - Test console

    /// Runs a request through the full pipeline without going over HTTP, so the
    /// in-app console exercises exactly the same routing and execution code.
    public func runConsole(logicalModel: String, prompt: String, systemPrompt: String?,
                           stream: Bool,
                           onEvent: @escaping @Sendable (CanonicalStreamEvent) -> Void)
        async -> Result<RequestRecord, DerbyError> {

        var request = CanonicalRequest(requestedModel: logicalModel)
        if let s = systemPrompt, !s.isEmpty { request.messages.append(.system(s)) }
        request.messages.append(.user(prompt))
        request.stream = stream

        let snap = await snapshot()
        let cursor = await state.nextCursor(for: logicalModel)
        let decision: RoutingDecision
        do { decision = try Router().route(RoutingRequest(request), snapshot: snap, roundRobinCursor: cursor) }
        catch let e as DerbyError { return .failure(e) }
        catch { return .failure(DerbyError(kind: .unknown, message: error.localizedDescription)) }

        let config = await state.currentConfig()
        let meta = RequestMeta(requestID: IDGenerator.requestID(), clientName: "Derby Console",
                               dialect: .chatCompletions, promptLogging: config.logging.promptLogging,
                               promptExcerpt: config.logging.promptLogging.storesContent ? prompt : nil)
        if executor == nil {
            executor = Executor(registry: adapters, transport: transport, secrets: secrets,
                                credentials: credentials, health: healthRegistry, telemetry: telemetry)
        }
        guard let executor else { return .failure(DerbyError(kind: .unknown, message: "Engine not ready.")) }

        if stream {
            do {
                for try await event in executor.stream(request, decision: decision, meta: meta) {
                    switch event {
                    case .canonical(let c): onEvent(c)
                    case .finished(let record): return .success(record)
                    case .failed(let e, let record):
                        _ = record
                        return .failure(e)
                    case .attemptStarted: break
                    }
                }
                return .failure(DerbyError(kind: .unknown, message: "Stream ended without a result."))
            } catch let e as DerbyError { return .failure(e) }
            catch { return .failure(DerbyError(kind: .unknown, message: error.localizedDescription)) }
        } else {
            do {
                let outcome = try await executor.execute(request, decision: decision, meta: meta)
                onEvent(.textDelta(outcome.response.message.joinedText))
                return .success(outcome.record)
            } catch let e as DerbyError { return .failure(e) }
            catch { return .failure(DerbyError(kind: .unknown, message: error.localizedDescription)) }
        }
    }

    // MARK: - Maintenance

    public func resetCircuit(_ key: TargetKey) async {
        await healthRegistry.resetCircuit(key)
    }
    public func setTargetDisabled(_ key: TargetKey, _ disabled: Bool) async {
        await healthRegistry.setDisabled(key, disabled)
    }
    public func resetHealth() async {
        await healthRegistry.reset()
    }
    /// Re-downloads the model metadata catalog and rebuilds the snapshot so the
    /// new numbers take effect immediately.
    public func refreshModelCatalog() async -> Result<Int, DerbyError> {
        let result = await RemoteModelCatalog.shared.refresh()
        if case .success = result { await rebuildSnapshot() }
        return result
    }

    /// Re-derives the routing snapshot from the current configuration. Model
    /// metadata is resolved during that build, so this is how improved catalog
    /// data reaches the request path without any config change.
    private func rebuildSnapshot() async {
        let current = await state.currentConfig()
        await state.setConfig(current)
    }

    public func modelCatalogStatus() -> (modelCount: Int, fetchedAt: Date?) {
        RemoteModelCatalog.shared.status
    }

    public func exportDiagnostics() async -> String {
        let config = await state.currentConfig()
        var out = "Derby diagnostics\n"
        out += "Gateway: \(status.displayName) on \(config.gateway.bindAddress):\(config.gateway.port)\n"
        out += "Providers: \(config.providers.count), Logical models: \(config.logicalModels.count)\n\n"
        out += await telemetry.exportDiagnostics()
        return out
    }
}

/// Small shim so `Security` stays out of the engine's imports.
private func SecRandomCopyBytesShim(_ bytes: inout [UInt8]) -> Int32 {
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    return 0
}
