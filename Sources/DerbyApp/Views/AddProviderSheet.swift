import SwiftUI
import DerbyCore

struct AddProviderSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onAdd: (UUID) -> Void

    @State private var category: ProviderCategory = .api
    @State private var kind: ProviderKind = .openai
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelNames = ""
    @State private var isTesting = false
    @State private var result: ConnectionTestResult?
    @State private var credentialHome = ""

    private var kinds: [ProviderKind] {
        ProviderKind.allCases.filter { $0.category == category }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    categoryPicker
                    kindPicker
                    form
                    if let result { resultView(result) }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 620)
        .onAppear { syncDefaults() }
        .onChange(of: kind) { _, _ in syncDefaults() }
        .onChange(of: category) { _, newValue in
            kind = kinds.first ?? .openai
            _ = newValue
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Provider").font(.title3.weight(.semibold))
                Text("Metered APIs, subscriptions you already pay for, local servers, or any OpenAI-compatible endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var categoryPicker: some View {
        Picker("", selection: $category) {
            ForEach(ProviderCategory.allCases, id: \.self) { c in
                Label(c.displayName, systemImage: c.symbol).tag(c)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if category == .subscription { subscriptionHelp }
            if category == .local { localHelp }
            Picker("Provider", selection: $kind) {
                ForEach(kinds, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var subscriptionHelp: some View {
        let findings = model.subscriptionFindings
        Card(title: "Signed-in CLIs on this Mac", systemImage: "person.badge.key") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings) { finding in
                    HStack(spacing: 8) {
                        Image(systemName: finding.available ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(finding.available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.kind.displayName).font(.callout)
                            Text(finding.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if finding.available {
                            Button("Use") { kind = finding.kind }
                                .buttonStyle(.link)
                        }
                    }
                }
                Text("Derby reads the credential your CLI already stored. It never asks for your password and, unless you turn on managed refresh, never writes to that credential.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var localHelp: some View {
        if !model.localFindings.isEmpty {
            Card(title: "Detected local servers", systemImage: "desktopcomputer") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.localFindings) { finding in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.kind.displayName).font(.callout)
                                Text("\(finding.baseURL) · \(finding.note)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") {
                                kind = finding.kind
                                baseURL = finding.baseURL
                                name = finding.kind.displayName
                                modelNames = finding.models.joined(separator: "\n")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private var form: some View {
        Card(title: "Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Display name") {
                    TextField(kind.displayName, text: $name).textFieldStyle(.roundedBorder)
                }
                if kind != .bedrock, kind.cliCredentialSource == nil {
                    LabeledContent("Base URL") {
                        TextField(kind.defaultBaseURL ?? "https://your-server/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                if kind.apiKeyRequirement.isUsed {
                    LabeledContent(kind.apiKeyRequirement == .required ? "API key" : "API key (optional)") {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField(kind.apiKeyRequirement.prompt, text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                            if kind.apiKeyRequirement == .optional {
                                Text("Many local and self-hosted endpoints accept requests without one. Leave this empty and Derby will not send an Authorization header at all.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if apiKey.isEmpty {
                                Text("\(kind.displayName) will reject requests without a key. You can add it later in Providers.")
                                    .font(.caption2).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let source = kind.cliCredentialSource {
                    accountDirectorySection(source)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models (one per line, optional)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $modelNames)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .glassSurface(.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(kind.supportsModelDiscovery
                         ? "Leave empty to discover models automatically after adding."
                         : "This provider does not publish a model list; Derby pre-fills the known ones.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Choosing which login this provider uses. Separate directories are what
    /// make several accounts of the same service usable at once.
    @ViewBuilder
    private func accountDirectorySection(_ source: CLICredentialSource) -> some View {
        let homes = LocalDiscovery.alternateHomes(for: source)
        let variable = CLICredentialReader.homeEnvironmentVariable(for: source)
        let selectedHome = credentialHome.isEmpty ? nil
            : URL(fileURLWithPath: (credentialHome as NSString).expandingTildeInPath)
        let signedIn = CLICredentialReader.isAvailable(source, home: selectedHome)
        let taken = Set(model.config.providers
            .filter { $0.auth.describesCLI == source }
            .map { $0.credentialHomeURL?.path ?? CLICredentialReader.defaultHome(for: source).path })

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: signedIn ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(signedIn ? .green : .orange)
                Text(signedIn
                     ? (accountLabel(source, home: selectedHome).map { "Signed in as \($0)" }
                        ?? "\(source.displayName) credentials found.")
                     : "No \(source.displayName) session in this directory yet.")
                    .font(.callout)
            }

            if variable != nil {
                Picker("Account directory", selection: $credentialHome) {
                    ForEach(homes) { home in
                        let used = taken.contains(home.path) ? "  (already added)" : ""
                        let label = home.accountLabel.map { "\($0)\(used)" }
                            ?? "\(home.isDefault ? "Default" : home.path)\(used)"
                        Text(label).tag(home.isDefault ? "" : home.path)
                    }
                    if !credentialHome.isEmpty, !homes.contains(where: { $0.path == credentialHome }) {
                        Text(credentialHome).tag(credentialHome)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    TextField("New directory, e.g. ~/.codex-work", text: $credentialHome)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { credentialHome = url.path }
                    }
                }

                if taken.contains(selectedHome?.path ?? CLICredentialReader.defaultHome(for: source).path) {
                    Label("Another provider already uses this directory — both would share one login.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                if !signedIn, let variable {
                    let target = (selectedHome ?? CLICredentialReader.defaultHome(for: source)).path
                    let command = "mkdir -p \(target) && \(variable)=\(target) \(source.loginCommand)"
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sign in to this account first:").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(command)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassSurface(.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            Button { model.copyToPasteboard(command, label: "Command") } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private func accountLabel(_ source: CLICredentialSource, home: URL?) -> String? {
        (try? CLICredentialReader.read(source, home: home))?.accountLabel
    }

    private func resultView(_ result: ConnectionTestResult) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.headline).font(.callout.weight(.medium))
                    ForEach(Array(result.details.enumerated()), id: \.offset) { _, d in
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Test Connection") { Task { await test() } }
                .disabled(isTesting)
            if isTesting { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Provider") { add() }
                .derbyProminentButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func syncDefaults() {
        name = kind.displayName
        baseURL = kind.defaultBaseURL ?? ""
        credentialHome = ""
        modelNames = ModelCatalog.presetModels(for: kind).joined(separator: "\n")
        result = nil
    }

    private func buildAccount() -> ProviderAccount {
        var account = ProviderFactory.template(for: kind, name: name.isEmpty ? kind.displayName : name)
        let trimmedHome = credentialHome.trimmingCharacters(in: .whitespaces)
        if !trimmedHome.isEmpty { account.credentialHomeOverride = trimmedHome }
        // Default the name to the signed-in identity so two accounts of the same
        // service are distinguishable at a glance.
        if name.isEmpty || name == kind.displayName,
           let source = kind.cliCredentialSource,
           let label = accountLabel(source, home: account.credentialHomeURL) {
            account.name = "\(kind.displayName) — \(label.split(separator: " ").first.map(String.init) ?? label)"
        }
        if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            account.baseURLOverride = baseURL.trimmingCharacters(in: .whitespaces)
        }
        let names = modelNames.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !names.isEmpty {
            account.models = names.map { ProviderFactory.makeModel(id: $0, kind: kind) }
        }
        if !apiKey.isEmpty {
            let ref = SecretRef.new("provider.key")
            account.auth = .apiKey(ref)
            try? model.engine.secrets.set(apiKey, for: ref)
        }
        return account
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        result = await model.engine.testConnection(buildAccount())
    }

    private func add() {
        var account = buildAccount()
        if account.models.isEmpty, let discovered = result?.discovered, !discovered.isEmpty {
            account.models = discovered.map { ProviderFactory.makeModel(id: $0.id, kind: kind, discovered: $0) }
        }
        let id = account.id
        Task {
            await model.mutate("Added \(account.name)") { $0.providers.append(account) }
            // Discover models in the background when the user gave none.
            if account.models.isEmpty, kind.supportsModelDiscovery,
               let found = try? await model.engine.discoverModels(account), !found.isEmpty {
                await model.mutate { config in
                    guard let index = config.providers.firstIndex(where: { $0.id == id }) else { return }
                    config.providers[index].models = found.map {
                        ProviderFactory.makeModel(id: $0.id, kind: account.kind, discovered: $0)
                    }
                }
                model.show(.success, "Discovered \(found.count) models for \(account.name)")
            }
            onAdd(id)
        }
        dismiss()
    }
}
