import Foundation
import SwiftUI
import DerbyCore

/// The single observable bridge between SwiftUI and `DerbyEngine`.
///
/// Everything the UI renders is a `@Published` snapshot refreshed from the
/// engine; the UI never reaches into the request path itself.
@MainActor
final class AppModel: ObservableObject {
    let engine: DerbyEngine

    @Published private(set) var config: DerbyConfig
    @Published private(set) var status: GatewayStatus = .stopped
    @Published private(set) var snapshot = RoutingSnapshot()
    @Published private(set) var endpoint: String = ""
    @Published private(set) var localKey: String = ""
    @Published private(set) var usage = UsageSummary()
    @Published private(set) var requests: [RequestRecord] = []
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var routingPaused = false
    @Published var startupWarnings: [String] = []

    @Published var banner: Banner?
    @Published var showOnboarding = false
    @Published var usageWindow: UsageWindow = .today
    @Published var requestFilter = RequestFilter()
    @Published var logLevel: LogLevel = .info

    /// Local-server and subscription discovery results, refreshed on demand.
    @Published private(set) var localFindings: [LocalDiscovery.Finding] = []
    @Published private(set) var subscriptionFindings: [LocalDiscovery.SubscriptionFinding] = []
    @Published private(set) var isScanning = false

    private var refreshTask: Task<Void, Never>?

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, success, warning, error }
        let id = UUID()
        var kind: Kind
        var title: String
        var detail: String?
    }

    struct RequestFilter: Equatable {
        var search = ""
        var logicalModel: String?
        var onlyFailures = false
        var onlyFailovers = false
    }

    init(engine: DerbyEngine = DerbyEngine()) {
        self.engine = engine
        self.config = DerbyConfig.seeded()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        await engine.bootstrap()
        await refreshAll()
        startupWarnings = await engine.startupWarnings
        showOnboarding = !config.app.hasCompletedOnboarding
        if config.app.autoDiscoverLocalServers { await scanForLocalServers() }
        startPolling()
    }

    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.refreshLive()
            }
        }
    }

    func shutdown() async {
        refreshTask?.cancel()
        await engine.stopGateway()
    }

    /// Cheap, frequent refresh: status and health only.
    func refreshLive() async {
        status = await engine.status
        snapshot = await engine.snapshot()
        endpoint = await engine.endpointURL
        routingPaused = await engine.isRoutingPaused()
    }

    /// Full refresh, including database queries.
    func refreshAll() async {
        config = await engine.config()
        await syncLocalKey()
        await refreshLive()
        await refreshUsage()
        await refreshRequests()
        await refreshLogs()
    }

    func refreshUsage() async {
        usage = await engine.telemetry.usage(window: usageWindow)
    }

    func refreshRequests() async {
        var query = RequestQuery()
        query.limit = 300
        query.searchText = requestFilter.search.isEmpty ? nil : requestFilter.search
        query.logicalModel = requestFilter.logicalModel
        query.onlyFailures = requestFilter.onlyFailures
        query.onlyFailovers = requestFilter.onlyFailovers
        requests = await engine.telemetry.requests(query)
    }

    func refreshLogs() async {
        logs = await engine.telemetry.logs(level: logLevel, limit: 500)
    }

    // MARK: - Gateway control

    func startGateway() async {
        do {
            try await engine.startGateway()
            await refreshLive()
            show(.success, "Gateway running", endpoint)
        } catch {
            await refreshLive()
            show(.error, "Could not start the gateway", error.localizedDescription)
        }
    }

    func stopGateway() async {
        await engine.stopGateway()
        await refreshLive()
        show(.info, "Gateway stopped")
    }

    func restartGateway() async {
        do {
            try await engine.restartGateway()
            await refreshLive()
            show(.success, "Gateway restarted", endpoint)
        } catch {
            await refreshLive()
            show(.error, "Could not restart the gateway", error.localizedDescription)
        }
    }

    func toggleRoutingPaused() async {
        await engine.setRoutingPaused(!routingPaused)
        await refreshLive()
    }

    // MARK: - Configuration

    /// Applies a configuration change and keeps the UI in sync.
    func mutate(_ label: String? = nil, _ body: @Sendable @escaping (inout DerbyConfig) -> Void) async {
        let result = await engine.update(body)
        switch result {
        case .success(let updated):
            config = updated
            await refreshLive()
            if let label { show(.success, label) }
        case .failure(let error):
            show(.error, "Could not save configuration", error.localizedDescription)
        }
    }

    func completeOnboarding() async {
        await mutate { $0.app.hasCompletedOnboarding = true }
        showOnboarding = false
    }

    /// Loads the local key for display only while it is switched on: fetching it
    /// can raise a Keychain dialog, and the default gateway has no key at all.
    func syncLocalKey() async {
        localKey = config.gateway.requireAPIKey ? await engine.localAPIKey() : ""
    }

    func regenerateLocalKey() async {
        localKey = await engine.regenerateLocalKey()
        show(.success, "New local API key generated", "Update any clients that use Derby.")
    }

    // MARK: - Discovery

    func scanForLocalServers() async {
        isScanning = true
        defer { isScanning = false }
        async let servers = LocalDiscovery.scan()
        let subs = LocalDiscovery.scanSubscriptions()
        localFindings = await servers
        subscriptionFindings = subs
    }

    /// Local servers that are running but not yet configured in Derby.
    var unconfiguredLocalFindings: [LocalDiscovery.Finding] {
        localFindings.filter { finding in
            !config.providers.contains { $0.baseURL == finding.baseURL.trimmedTrailingSlash }
        }
    }

    var unconfiguredSubscriptions: [LocalDiscovery.SubscriptionFinding] {
        subscriptionFindings.filter { finding in
            finding.available && !config.providers.contains { $0.kind == finding.kind }
        }
    }

    // MARK: - Derived views for the UI

    func health(for target: ResolvedTarget) -> TargetHealth {
        snapshot.health(for: target.key)
    }

    func health(providerID: UUID, modelID: String) -> TargetHealth {
        snapshot.health(for: TargetKey(providerID: providerID, modelID: modelID))
    }

    var providerHealthSummaries: [ProviderHealthSummary] {
        config.providers.map { account in
            let states = account.models.filter(\.enabled).map {
                snapshot.health(for: TargetKey(providerID: account.id, modelID: $0.modelID))
            }
            return ProviderHealthSummary(account: account, targets: states)
        }
    }

    var unavailableProviders: [ProviderHealthSummary] {
        providerHealthSummaries.filter { $0.account.enabled && !$0.isUsable }
    }

    /// Logical models that currently have at least one usable target.
    var activeLogicalModels: [ResolvedLogicalModel] {
        snapshot.logicalModels.values
            .sorted { $0.name < $1.name }
            .filter { !$0.targets.isEmpty }
    }

    func resolved(_ model: LogicalModel) -> ResolvedLogicalModel? {
        snapshot.logicalModel(named: model.name)
    }

    // MARK: - Banners

    func show(_ kind: Banner.Kind, _ title: String, _ detail: String? = nil) {
        banner = Banner(kind: kind, title: title, detail: detail)
        let id = banner?.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.banner?.id == id else { return }
            self.banner = nil
        }
    }

    func copyToPasteboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(.success, "\(label) copied")
    }
}

struct ProviderHealthSummary: Identifiable {
    var account: ProviderAccount
    var targets: [TargetHealth]
    var id: UUID { account.id }

    var openCircuits: Int { targets.filter { $0.circuit == .open }.count }
    var worstState: HealthState {
        guard !targets.isEmpty else { return .unknown }
        return targets.min { $0.state.scoreValue < $1.state.scoreValue }?.state ?? .unknown
    }
    var isUsable: Bool {
        guard account.enabled else { return false }
        guard !targets.isEmpty else { return account.models.contains(where: \.enabled) }
        return targets.contains { $0.state.isRoutable && $0.circuit != .open }
    }
    var detail: String {
        if !account.enabled { return "Disabled" }
        if account.models.filter(\.enabled).isEmpty { return "No models enabled" }
        if openCircuits > 0 { return "\(openCircuits) circuit\(openCircuits == 1 ? "" : "s") open" }
        return worstState.displayName
    }
}
