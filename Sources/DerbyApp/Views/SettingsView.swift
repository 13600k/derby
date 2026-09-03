import SwiftUI
import DerbyCore
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var portText = ""
    @State private var confirmReset = false

    var body: some View {
        Page(title: "Settings", subtitle: "Gateway, application and data") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                gatewayCard
                securityCard
                applicationCard
                loggingCard
                dataCard
                aboutCard
            }
        }
        .task { portText = String(model.config.gateway.port) }
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
                    Label("Derby is reachable from your network. Keep the local API key enabled.",
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
                            await model.restartGateway()
                        }
                    }))
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
