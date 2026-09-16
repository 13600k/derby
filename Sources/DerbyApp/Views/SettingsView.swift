import SwiftUI
import DerbyCore
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var portText = ""
    @State private var confirmReset = false
    @State private var isRefreshingCatalog = false
    @State private var isRefreshingBenchmarks = false
    @State private var benchmarkKeyInput = ""
    @State private var benchmarkKeyLoaded = false

    var body: some View {
        Page(title: "Settings", subtitle: "Gateway, application and data") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                gatewayCard
                securityCard
                applicationCard
                catalogCard
                benchmarksCard
                loggingCard
                dataCard
                aboutCard
            }
        }
        .task {
            portText = String(model.config.gateway.port)
            if !benchmarkKeyLoaded {
                benchmarkKeyInput = model.engine.secrets.get(model.config.benchmarks.apiKeyRef) ?? ""
                benchmarkKeyLoaded = true
            }
        }
    }

    // MARK: - Gateway

    private var gatewayCard: some View {
        Card(title: "Gateway", subtitle: "Changes to the port or bind address need a restart",
             systemImage: "network") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Port").font(.caption).foregroundStyle(.secondary)
                        TextField("8787", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit { commitPort() }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bind address").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { model.config.gateway.bindAddress },
                            set: { newValue in
                                Task { await model.mutate { $0.gateway.bindAddress = newValue } }
                            })) {
                            Text("127.0.0.1 (this Mac only)").tag("127.0.0.1")
                            Text("0.0.0.0 (all interfaces)").tag("0.0.0.0")
                        }
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    Spacer()
                }
                if model.config.gateway.bindAddress != "127.0.0.1" {
                    Label(model.config.gateway.requireAPIKey
                          ? "Derby is reachable from your network. Keep the local API key enabled."
                          : "Derby is reachable from your network with no API key. Turn on \"Require the local API key\" below.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Start the gateway when Derby launches", isOn: Binding(
                    get: { model.config.gateway.autoStart },
                    set: { newValue in Task { await model.mutate { $0.gateway.autoStart = newValue } } }))
                NumberField(label: "Max concurrent requests",
                            value: Binding(
                                get: { model.config.gateway.maxConcurrentRequests },
                                set: { newValue in
                                    Task { await model.mutate { $0.gateway.maxConcurrentRequests = newValue } }
                                }),
                            range: 1...512, onCommit: {})
                    .frame(width: 190)

                Divider()
                CopyableField(label: "Base URL for clients", value: model.endpoint) {
                    model.copyToPasteboard($0, label: "Endpoint")
                }
                .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("Restart Gateway") { Task { await model.restartGateway() } }
                    Button("Stop Gateway") { Task { await model.stopGateway() } }
                        .disabled(!model.status.isRunning)
                    Spacer()
                }
            }
        }
    }

    private var securityCard: some View {
        Card(title: "Access", systemImage: "lock") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Require the local API key", isOn: Binding(
                    get: { model.config.gateway.requireAPIKey },
                    set: { newValue in
                        Task {
                            await model.mutate { $0.gateway.requireAPIKey = newValue }
                            await model.syncLocalKey()
                            await model.restartGateway()
                        }
                    }))
                if model.config.gateway.requireAPIKey {
                    CopyableField(label: "Local API key", value: model.localKey, isSecret: true) {
                        model.copyToPasteboard($0, label: "API key")
                    }
                    .frame(maxWidth: 460)
                    HStack {
                        Button("Regenerate Key") {
                            Task {
                                await model.regenerateLocalKey()
                                await model.restartGateway()
                            }
                        }
                        Spacer()
                    }
                } else {
                    Text("Clients need only the base URL. Derby ignores any API key they send, so tools that insist on one can use any value.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Credentials for providers live in the macOS Keychain. Derby's configuration file contains only references to them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var applicationCard: some View {
        Card(title: "Application", systemImage: "macwindow") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch Derby at login", isOn: Binding(
                    get: { model.config.app.launchAtLogin },
                    set: { newValue in
                        setLaunchAtLogin(newValue)
                        Task { await model.mutate { $0.app.launchAtLogin = newValue } }
                    }))
                Toggle("Show the menu bar item", isOn: Binding(
                    get: { model.config.app.showMenuBarExtra },
                    set: { newValue in Task { await model.mutate { $0.app.showMenuBarExtra = newValue } } }))
                Toggle("Keep the gateway running when the window is closed", isOn: Binding(
                    get: { model.config.app.keepRunningWhenWindowClosed },
                    set: { newValue in Task { await model.mutate { $0.app.keepRunningWhenWindowClosed = newValue } } }))
                Toggle("Look for local model servers automatically", isOn: Binding(
                    get: { model.config.app.autoDiscoverLocalServers },
                    set: { newValue in Task { await model.mutate { $0.app.autoDiscoverLocalServers = newValue } } }))
                Button("Show Welcome Guide Again") {
                    Task { await model.mutate { $0.app.hasCompletedOnboarding = false } }
                    model.showOnboarding = true
                }
                .buttonStyle(.link)
            }
        }
    }

    private var loggingCard: some View {
        Card(title: "Logging & retention", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Prompt logging", selection: Binding(
                    get: { model.config.logging.promptLogging },
                    set: { newValue in
                        Task {
                            await model.mutate { $0.logging.promptLogging = newValue }
                            await model.restartGateway()
                        }
                    })) {
                    ForEach(PromptLoggingMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 340)
                Text("Derby stores request metadata by default. Prompt and response text are only kept when you ask for it.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Log level", selection: Binding(
                    get: { model.config.logging.level },
                    set: { newValue in Task { await model.mutate { $0.logging.level = newValue } } })) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 340)

                AdaptiveGrid(minWidth: 190) {
                    NumberField(label: "Request history retention (days)",
                                value: Binding(
                                    get: { model.config.logging.historyRetentionDays },
                                    set: { v in Task { await model.mutate { $0.logging.historyRetentionDays = v } } }),
                                range: 0...3650, onCommit: {})
                    NumberField(label: "Max history rows",
                                value: Binding(
                                    get: { model.config.logging.maxHistoryRows },
                                    set: { v in Task { await model.mutate { $0.logging.maxHistoryRows = v } } }),
                                range: 100...1_000_000, onCommit: {})
                    NumberField(label: "Log retention (days)",
                                value: Binding(
                                    get: { model.config.logging.logRetentionDays },
                                    set: { v in Task { await model.mutate { $0.logging.logRetentionDays = v } } }),
                                range: 0...365, onCommit: {})
                }
            }
        }
    }

    private var catalogCard: some View {
        let status = model.engine.modelCatalogStatus()
        return Card(title: "Model metadata",
                    subtitle: "Context windows, modalities and list prices for known models",
                    systemImage: "books.vertical") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Provider APIs rarely report a model's context window, so Derby keeps a catalog of model metadata and refreshes it in the background. Discovered facts from a provider always win; this fills the gaps.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DetailRow(label: "Models known", value: status.modelCount == 0 ? "none yet" : "\(status.modelCount)")
                DetailRow(label: "Last updated",
                          value: status.fetchedAt.map { Format.relative($0) } ?? "never")
                HStack(spacing: 10) {
                    Button {
                        Task {
                            isRefreshingCatalog = true
                            defer { isRefreshingCatalog = false }
                            switch await model.engine.refreshModelCatalog() {
                            case .success(let count):
                                await model.refreshLive()
                                model.show(.success, "Model catalog updated", "\(count) models known.")
                            case .failure(let error):
                                model.show(.error, "Could not update the model catalog", error.message)
                            }
                        }
                    } label: {
                        if isRefreshingCatalog { ProgressView().controlSize(.small) }
                        else { Label("Update Now", systemImage: "arrow.down.circle") }
                    }
                    .disabled(isRefreshingCatalog)
                    Spacer()
                }
                Text("Source: models.dev")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Benchmarks

    private var benchmarksCard: some View {
        let status = model.engine.benchmarkCatalogStatus()
        let settings = model.config.benchmarks
        return Card(title: "Benchmarks",
                    subtitle: "Independent scores from Artificial Analysis",
                    systemImage: "chart.bar.doc.horizontal") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Weighted-score routing ranks targets by an intelligence score that Derby otherwise asks you to invent for every model. Artificial Analysis publishes one, along with prices and measured speeds. Use the Specs buttons on a provider to copy them into its models — nothing is fetched or changed until you do.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API key").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SecureField("Paste your Artificial Analysis API key", text: $benchmarkKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveBenchmarkKey)
                            .frame(maxWidth: 360)
                        Button("Save", action: saveBenchmarkKey)
                            .disabled(benchmarkKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Create one at artificialanalysis.ai → API. The free tier allows 1,000 requests a day; Derby downloads the whole index at most once a day and looks models up from its own cache.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Plan", selection: Binding(
                    get: { settings.tier },
                    set: { newValue in Task { await model.mutate { $0.benchmarks.tier = newValue } } })) {
                    ForEach(BenchmarkTier.allCases, id: \.self) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                if settings.tier == .free {
                    Text("The free endpoint omits context windows; the Pro one includes them.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()
                Text("What a fetch writes").font(.caption).foregroundStyle(.secondary)
                Toggle("Intelligence score (used by weighted-score routing)", isOn: Binding(
                    get: { settings.applyIntelligenceScore },
                    set: { v in Task { await model.mutate { $0.benchmarks.applyIntelligenceScore = v } } }))
                Toggle("Input and output prices", isOn: Binding(
                    get: { settings.applyPricing },
                    set: { v in Task { await model.mutate { $0.benchmarks.applyPricing = v } } }))
                if settings.applyPricing {
                    Toggle("…including prices you have already entered", isOn: Binding(
                        get: { settings.overwriteExistingPricing },
                        set: { v in Task { await model.mutate { $0.benchmarks.overwriteExistingPricing = v } } }))
                        .padding(.leading, 18)
                    Text("Local and subscription targets are always skipped: their marginal cost is zero whatever the hosted copy of the same model is billed at.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Context window, when nothing else reported one", isOn: Binding(
                    get: { settings.applyContextWindow },
                    set: { v in Task { await model.mutate { $0.benchmarks.applyContextWindow = v } } }))
                if settings.appliesNothing {
                    Label("With all three off, a fetch records the scores for reference but changes nothing.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                DetailRow(label: "Models scored", value: status.modelCount == 0 ? "none yet" : "\(status.modelCount)")
                DetailRow(label: "Last updated",
                          value: status.fetchedAt.map { Format.relative($0) } ?? "never")
                if let version = status.indexVersion {
                    DetailRow(label: "Index methodology", value: "v\(version)")
                }
                HStack(spacing: 10) {
                    Button {
                        Task {
                            isRefreshingBenchmarks = true
                            defer { isRefreshingBenchmarks = false }
                            switch await model.engine.refreshBenchmarkCatalog() {
                            case .success(let count):
                                await model.refreshLive()
                                model.show(.success, "Benchmark data updated", "\(count) models scored.")
                            case .failure(let error):
                                model.show(.error, "Could not update benchmark data", error.message)
                            }
                        }
                    } label: {
                        if isRefreshingBenchmarks { ProgressView().controlSize(.small) }
                        else { Label("Update Now", systemImage: "arrow.down.circle") }
                    }
                    .disabled(isRefreshingBenchmarks)
                    Spacer()
                }
                Text("Source: artificialanalysis.ai. Scores are only comparable within one methodology version.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveBenchmarkKey() {
        let value = benchmarkKeyInput.trimmingCharacters(in: .whitespaces)
        do {
            try model.engine.secrets.set(value.isEmpty ? nil : value,
                                         for: model.config.benchmarks.apiKeyRef)
            model.show(.success, value.isEmpty ? "Benchmark API key removed" : "Benchmark API key saved to Keychain")
        } catch {
            model.show(.error, "Could not save the API key", error.localizedDescription)
        }
    }

    private var dataCard: some View {
        Card(title: "Configuration & data", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Export Configuration…") { exportConfig() }
                    Button("Import Configuration…") { importConfig() }
                    Spacer()
                }
                Text("Exports never contain secrets. After importing, re-enter each provider's credentials.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()
                HStack(spacing: 10) {
                    Button("Reveal Data Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configFile])
                    }
                    Button("Clear Request History") {
                        Task {
                            await model.engine.telemetry.clearHistory()
                            await model.refreshRequests()
                            await model.refreshUsage()
                            model.show(.success, "Request history cleared")
                        }
                    }
                    Button("Reset Health & Circuits") {
                        Task {
                            await model.engine.resetHealth()
                            await model.refreshLive()
                            model.show(.success, "Health statistics reset")
                        }
                    }
                    Spacer()
                }
                Text(AppPaths.supportDirectory.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var aboutCard: some View {
        Card(title: "About Derby", systemImage: "flag.checkered") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Derby routes one local OpenAI-compatible endpoint across many providers.")
                    .font(.callout)
                DetailRow(label: "Version", value: "1.0")
                DetailRow(label: "Configuration", value: AppPaths.configFile.lastPathComponent, monospaced: true)
                DetailRow(label: "Database", value: AppPaths.databaseFile.lastPathComponent, monospaced: true)
                DetailRow(label: "Providers configured", value: "\(model.config.providers.count)")
                DetailRow(label: "Logical models", value: "\(model.config.logicalModels.count)")
            }
        }
    }

    // MARK: - Actions

    private func commitPort() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else {
            portText = String(model.config.gateway.port)
            model.show(.warning, "Port must be between 1 and 65535")
            return
        }
        Task {
            await model.mutate { $0.gateway.port = port }
            if model.status.isRunning { await model.restartGateway() }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            model.show(.warning, "Could not change the login item",
                       "macOS reported: \(error.localizedDescription). You can add Derby manually in System Settings → General → Login Items.")
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "derby-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ConfigStore.export(model.config)
            try data.write(to: url)
            model.show(.success, "Configuration exported", "Secrets were not included.")
        } catch {
            model.show(.error, "Export failed", error.localizedDescription)
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let (imported, warnings) = try ConfigStore.importConfig(from: data)
            Task {
                await model.mutate("Configuration imported") { config in
                    // Keep this machine's gateway identity; import everything else.
                    var incoming = imported
                    incoming.gateway.localKeyRef = config.gateway.localKeyRef
                    incoming.app.hasCompletedOnboarding = true
                    config = incoming
                }
                await model.refreshAll()
                if !warnings.isEmpty {
                    model.show(.warning, "Imported with notes", warnings.joined(separator: " "))
                }
                await model.restartGateway()
            }
        } catch {
            model.show(.error, "Import failed", error.localizedDescription)
        }
    }
}
