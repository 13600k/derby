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
    /// What each local server has loaded, refreshed while the gateway runs.
    public nonisolated let residency = ResidencyRegistry()
    /// Who wrote each answer, shared by the gateway and the executor.
    public nonisolated let handoffLedger = HandoffLedger()
    /// Each cloud account's plan meter, for the dashboard. Polled only once
    /// `startUsagePolling` is called, so an engine a test boots stays quiet.
    public nonisolated let usageMonitor: UsageMonitor
    private let adapters: AdapterRegistry
    private var residencyTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?

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

        let state = ControlPlaneState(config: config)
        let telemetry = telemetry ?? TelemetryStore(settings: config.logging)
        self.state = state
        self.telemetry = telemetry
        self.healthRegistry = HealthRegistry(settings: config.health)

        let transport = self.transport, secrets = self.secrets, credentials = self.credentials
        self.usageMonitor = UsageMonitor(
            accounts: { await state.currentConfig().providers },
            fetch: { account, interactive in
                let ctx = ProviderContext(account: account, transport: transport, secrets: secrets,
                                          credentials: credentials, attemptTimeout: 20,
                                          mayPromptForCredentials: interactive)
                return try await adapters.adapter(for: account.kind).usage(ctx)
            },
            tallies: { since in await telemetry.requestTallies(since: since) },
            log: { level, message in
                await telemetry.log(LogEntry(level: level, category: "usage", message: message))
            })
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
        // Before the gateway starts, so the first request after a restart already
        // continues the conversations Derby was carrying.
        await handoffLedger.attach(store: SQLiteHandoffLedgerStore(path: telemetry.path))
        await telemetry.update(settings: config.logging)
        await healthRegistry.update(settings: config.health)
        await healthRegistry.update(accountLimits: accountLimits(config))
        executor = Executor(registry: adapters, transport: transport, secrets: secrets,
                            credentials: credentials, health: healthRegistry, telemetry: telemetry,
                                ledger: handoffLedger)
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
        let live = await healthRegistry.snapshotWithLoad()
        var snap = await state.snapshot(health: live.health)
        snap.accountLoad = live.accountLoad
        snap.loadVersion = live.loadVersion
        snap.residency = await residency.snapshot()
        return snap
    }

    // MARK: - Loaded models

    /// Asks each enabled local server, every few seconds, which models it has in
    /// memory. Runs only while the gateway does.
    private func startResidencyPolling() {
        residencyTask?.cancel()
        let state = self.state, adapters = self.adapters, transport = self.transport
        let secrets = self.secrets, credentials = self.credentials, registry = residency
        residencyTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let config = await state.currentConfig()
                await DerbyEngine.pollResidency(config: config, adapters: adapters, transport: transport,
                                                secrets: secrets, credentials: credentials, into: registry)
                try? await Task.sleep(nanoseconds: UInt64(ModelResidency.pollInterval * 1_000_000_000))
            }
        }
    }

    static func pollResidency(config: DerbyConfig, adapters: AdapterRegistry, transport: any HTTPTransport,
                              secrets: any SecretStore, credentials: CredentialCache,
                              into registry: ResidencyRegistry) async {
        await withTaskGroup(of: Void.self) { group in
            for account in config.providers where account.enabled && account.kind.isLocal {
                group.addTask {
                    let adapter = adapters.adapter(for: account.kind)
                    let ctx = ProviderContext(account: account, transport: transport, secrets: secrets,
                                              credentials: credentials, attemptTimeout: 2)
                    // Two questions, both optional: which models are in memory,
                    // and what the server is working on. A server that answers
                    // neither is one Derby stops claiming to know anything about.
                    let loaded = try? await withDeadline(3, message: "loaded-model probe timed out") {
                        try await adapter.loadedModels(ctx)
                    }
                    let busy = try? await withDeadline(3, message: "occupancy probe timed out") {
                        try await adapter.occupancy(ctx)
                    }
                    switch (loaded ?? nil, busy ?? nil) {
                    case (nil, nil):
                        await registry.forget(accountID: account.id)
                    case (let models, let occupancy):
                        await registry.update(accountID: account.id, loadedModels: models,
                                              occupancy: occupancy)
                    }
                }
            }
        }
    }

    // MARK: - Plan usage

    /// Keeps `usageMonitor` current for as long as the app runs, gateway or
    /// not: a plan's meter is worth seeing while nothing is being routed.
    public func startUsagePolling() {
        usageTask?.cancel()
        let monitor = usageMonitor
        usageTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await monitor.refresh()
                try? await Task.sleep(nanoseconds: UInt64(UsageMonitor.tickInterval * 1_000_000_000))
            }
        }
    }

    /// Reads every meter now, unless it was read in the last half minute.
    /// Something the user asked for, so a login kept in the Keychain may be
    /// read — and the system may ask first.
    public func refreshProviderUsage() async {
        await usageMonitor.refresh(force: true)
    }

    public func providerUsage() async -> [UUID: ProviderUsageStatus] {
        await usageMonitor.snapshot()
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
                                credentials: credentials, health: healthRegistry, telemetry: telemetry,
                                ledger: handoffLedger)
        }
        let handler = GatewayHandler(state: state, health: healthRegistry, telemetry: telemetry,
                                     executor: executor, secrets: secrets,
                                     gatewaySettings: config.gateway,
                                     localAPIKey: cachedLocalKey,
                                     promptLogging: config.logging.promptLogging,
                                     residency: residency)
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
            startResidencyPolling()
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
        residencyTask?.cancel()
        residencyTask = nil
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
        // Discovery is a live poll, not a cache read. The shared metadata index
        // is refreshed first so a model released since Derby last looked is
        // described from current data rather than from the bundled fallback
        // table, which by design always trails what people are actually running.
        // A failure here is not fatal: the previous index stays in place.
        _ = await RemoteModelCatalog.shared.refresh(timeout: 20)
        let adapter = adapters.adapter(for: account.kind)
        return try await adapter.listModels(context(for: account))
    }

    // MARK: - Benchmarks

    /// What one benchmark fetch did.
    public struct BenchmarkReport: Sendable {
        /// Models the index had an entry for, and what changed on each.
        public var outcomes: [BenchmarkApplication.Outcome]
        /// How many models the index is carrying, after any refresh.
        public var catalogCount: Int
        public var indexVersion: String?
        /// Set when the download failed. Non-fatal on its own: a previously
        /// cached index is still applied, and saying so is the point.
        public var error: DerbyError?
        /// Targets whose logical model pins a quality of its own, which still
        /// wins over the score just fetched. Reported rather than overridden:
        /// a number that disagrees with the model's own was a deliberate choice.
        public var stillPinned: [String] = []

        public var matched: [BenchmarkApplication.Outcome] { outcomes.filter(\.isMatched) }
        public var unmatched: [String] { outcomes.filter { !$0.isMatched }.map(\.modelID) }
        public var changeCount: Int { outcomes.reduce(0) { $0 + $1.changes.count } }

        public var headline: String {
            if outcomes.isEmpty { return "No models to look up" }
            let n = matched.count
            if n == 0 { return "Artificial Analysis lists none of these models" }
            return "Updated \(n) model\(n == 1 ? "" : "s") from Artificial Analysis"
        }
    }

    /// Fetches Artificial Analysis scores and copies them into a provider's
    /// models, or into named models of it.
    ///
    /// The download is skipped when the cached index is still fresh, so pressing
    /// the button on ten models in a row costs one request, not ten — the free
    /// tier allows a thousand a day and the data moves weekly at most.
    public func applyBenchmarks(providerID: UUID,
                                modelIDs: [String]? = nil,
                                forceRefresh: Bool = false) async -> BenchmarkReport {
        let config = await state.currentConfig()
        let settings = config.benchmarks
        let catalog = BenchmarkCatalog.shared

        var fetchError: DerbyError?
        if forceRefresh || catalog.isStale {
            // The Keychain is only reached for this when a fetch is actually
            // due, and never on the request path.
            let key = secrets.get(settings.apiKeyRef)
            let result = await catalog.refresh(apiKey: key, tier: settings.tier,
                                               transport: transport, timeout: 30)
            if case .failure(let error) = result { fetchError = error }
        }

        // Nothing cached and nothing downloaded: there is no data to apply, and
        // reporting "matched 0 models" would hide why.
        guard catalog.status.modelCount > 0 else {
            return BenchmarkReport(outcomes: [], catalogCount: 0, indexVersion: nil,
                                   error: fetchError ?? DerbyError(
                                    kind: .transient,
                                    message: "No benchmark data yet. Add an Artificial Analysis API key in Settings → Benchmarks."))
        }

        let indexVersion = catalog.indexVersion
        var outcomes: [BenchmarkApplication.Outcome] = []
        var rewritten: [UUID: PhysicalModel] = [:]
        var previousScores: [UUID: Double] = [:]
        let now = Date()

        // Worked out first, then written in one pass: `update` takes a
        // `@Sendable` closure, which cannot mutate anything captured from here.
        if let account = config.provider(id: providerID) {
            for model in account.models {
                if let modelIDs, !modelIDs.contains(model.modelID) { continue }
                guard let entry = catalog.lookup(model.modelID) else {
                    outcomes.append(BenchmarkApplication.Outcome(modelID: model.modelID,
                                                                 matched: nil, changes: []))
                    continue
                }
                // The window the router would otherwise use, so the index only
                // ever fills a blank rather than contradicting the provider.
                let catalogCaps = ModelCatalog.metadata(for: model.modelID, kind: account.kind).capabilities
                let known = model.capabilities.contextWindow ?? catalogCaps.contextWindow

                var updated = model
                previousScores[model.id] = model.qualityScore
                let changes = BenchmarkApplication.apply(entry, to: &updated, kind: account.kind,
                                                        settings: settings,
                                                        knownContextWindow: known,
                                                        indexVersion: indexVersion,
                                                        now: now)
                rewritten[model.id] = updated
                outcomes.append(BenchmarkApplication.Outcome(modelID: model.modelID,
                                                             matched: entry.name, changes: changes))
            }
        }

        // A logical model may pin a target's quality, which overrides the
        // model's own score everywhere routing reads it. A pin that merely
        // mirrored the old score was never a decision — the quality field in
        // the logical model view writes one on any commit, so tabbing through
        // it froze the target at that moment — and leaving it would make a
        // fetched score appear to do nothing. One that says something different
        // is a real choice and is kept, and reported so it is never a mystery.
        var unpin = Set<UUID>()
        var shadowed: [(model: String, logicalModel: String, pinned: Double)] = []
        for logical in config.logicalModels {
            for ref in logical.targets {
                guard let pinned = ref.qualityOverride,
                      let updated = rewritten[ref.modelUUID],
                      let previous = previousScores[ref.modelUUID],
                      abs(updated.qualityScore - previous) >= 0.5 else { continue }
                if abs(pinned - previous) < 0.5 {
                    unpin.insert(ref.id)
                } else {
                    shadowed.append((updated.modelID, logical.name, pinned))
                }
            }
        }

        if !rewritten.isEmpty {
            let applied = rewritten
            let unpinned = unpin
            let result = await update { config in
                guard let accountIndex = config.providers.firstIndex(where: { $0.id == providerID })
                else { return }
                for modelIndex in config.providers[accountIndex].models.indices {
                    let id = config.providers[accountIndex].models[modelIndex].id
                    if let model = applied[id] { config.providers[accountIndex].models[modelIndex] = model }
                }
                guard !unpinned.isEmpty else { return }
                for logicalIndex in config.logicalModels.indices {
                    for refIndex in config.logicalModels[logicalIndex].targets.indices
                    where unpinned.contains(config.logicalModels[logicalIndex].targets[refIndex].id) {
                        config.logicalModels[logicalIndex].targets[refIndex].qualityOverride = nil
                    }
                }
            }
            if case .failure(let error) = result {
                return BenchmarkReport(outcomes: outcomes, catalogCount: catalog.status.modelCount,
                                       indexVersion: indexVersion,
                                       error: DerbyError(kind: .transient,
                                                         message: error.localizedDescription))
            }
        }

        if !unpin.isEmpty {
            for index in outcomes.indices where !outcomes[index].changes.isEmpty {
                outcomes[index].changes.append(BenchmarkApplication.Change(
                    field: "logical models", before: "pinned to the old score",
                    after: "following this model again"))
            }
        }

        await telemetry.log(LogEntry(level: fetchError == nil ? .info : .warn, category: "benchmarks",
                                     message: "Artificial Analysis: matched \(outcomes.filter(\.isMatched).count)/\(outcomes.count) models"
                                        + (fetchError.map { ", download failed: \($0.message)" } ?? "")))

        return BenchmarkReport(outcomes: outcomes, catalogCount: catalog.status.modelCount,
                               indexVersion: indexVersion, error: fetchError,
                               stillPinned: shadowed.map {
                                   "\($0.model) in “\($0.logicalModel)” stays pinned at \(Int($0.pinned))"
                               })
    }

    /// Downloads the index without applying it, for the Settings screen.
    public func refreshBenchmarkCatalog() async -> Result<Int, DerbyError> {
        let settings = await state.currentConfig().benchmarks
        return await BenchmarkCatalog.shared.refresh(apiKey: secrets.get(settings.apiKeyRef),
                                                     tier: settings.tier,
                                                     transport: transport, timeout: 30)
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
                                credentials: credentials, health: healthRegistry, telemetry: telemetry,
                                ledger: handoffLedger)
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

    public nonisolated func benchmarkCatalogStatus() -> (modelCount: Int, fetchedAt: Date?, indexVersion: String?) {
        BenchmarkCatalog.shared.status
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
