import SwiftUI
import DerbyCore

struct ProviderDetailView: View {
    @EnvironmentObject private var model: AppModel
    let accountID: UUID

    @State private var draft: ProviderAccount?
    @State private var apiKeyInput = ""
    @State private var apiKeyLoaded = false
    @State private var testResult: ConnectionTestResult?
    @State private var isTesting = false
    @State private var isDiscovering = false
    @State private var modelToAdd = ""
    @State private var confirmDelete = false
    @State private var probingModel: String?

    private var account: ProviderAccount? {
        model.config.providers.first { $0.id == accountID }
    }

    var body: some View {
        Group {
            if let draft {
                content(draft)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func load() {
        guard let account else { return }
        draft = account
        homeInput = account.credentialHomeOverride ?? ""
        if case .apiKey(let ref) = account.auth {
            apiKeyInput = model.engine.secrets.get(ref) ?? ""
            apiKeyLoaded = true
        } else if case .customHeader(_, let ref, _) = account.auth {
            apiKeyInput = model.engine.secrets.get(ref) ?? ""
            apiKeyLoaded = true
        }
    }

    private func content(_ current: ProviderAccount) -> some View {
        Page(title: current.name, subtitle: current.kind.displayName) {
            HStack(spacing: 8) {
                Toggle("Enabled", isOn: binding(\.enabled))
                    .toggleStyle(.switch)
                    .onChange(of: current.enabled) { _, _ in save() }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
                .help("Remove this provider")
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                connectionCard(current)
                if let result = testResult { testResultCard(result) }
                credentialsCard(current)
                modelsCard(current)
                limitsCard(current)
                advancedCard(current)
            }
        }
        .confirmationDialog("Remove \(current.name)?", isPresented: $confirmDelete) {
            Button("Remove Provider", role: .destructive) { delete() }
        } message: {
            Text("Its models will be removed from every logical model that uses them. Stored credentials are deleted from the Keychain.")
        }
    }

    // MARK: - Cards

    private func connectionCard(_ current: ProviderAccount) -> some View {
        Card(title: "Connection", systemImage: "link") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Display name") {
                    TextField("", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                }
                if current.kind != .bedrock {
                    LabeledContent("Base URL") {
                        TextField(current.kind.defaultBaseURL ?? "https://…/v1",
                                  text: optionalBinding(\.baseURLOverride))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(save)
                    }
                }
                if current.kind == .azureOpenAI {
                    LabeledContent("API version") {
                        TextField("2024-10-21", text: optionalBinding(\.apiVersion))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                    }
                }
                if case .awsSigV4(_, _, _, let region) = current.auth {
                    LabeledContent("AWS region") {
                        TextField("us-east-1", text: Binding(
                            get: { region },
                            set: { newValue in
                                guard case .awsSigV4(let a, let s, let t, _) = draft?.auth else { return }
                                draft?.auth = .awsSigV4(accessKeyRef: a, secretKeyRef: s,
                                                        sessionTokenRef: t, region: newValue)
                            }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await test() }
                    } label: {
                        if isTesting { ProgressView().controlSize(.small).frame(width: 90) }
                        else { Text("Test Connection").frame(width: 90) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting)

                    if current.kind.supportsModelDiscovery {
                        Button {
                            Task { await discover() }
                        } label: {
                            if isDiscovering { ProgressView().controlSize(.small) }
                            else { Label("Discover Models", systemImage: "sparkle.magnifyingglass") }
                        }
                        .disabled(isDiscovering)
                    }
                    Spacer()
                }
            }
        }
    }

    private func testResultCard(_ result: ConnectionTestResult) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(result.ok ? .green : .red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.headline).font(.headline)
                    ForEach(Array(result.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if result.ok && !result.discovered.isEmpty {
                        Button("Import \(result.discovered.count) discovered model\(result.discovered.count == 1 ? "" : "s")") {
                            importModels(result.discovered)
                        }
                        .buttonStyle(.link)
                    }
                }
                Spacer()
                Button { testResult = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func credentialsCard(_ current: ProviderAccount) -> some View {
        Card(title: "Authentication", subtitle: current.auth.displayName, systemImage: "key") {
            switch current.auth {
            case .none:
                Text("This endpoint is used without credentials.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Add an API key") {
                    draft?.auth = .apiKey(.new("provider.key"))
                    apiKeyInput = ""
                    save()
                }
                .buttonStyle(.link)

            case .apiKey(let ref), .customHeader(_, let ref, _):
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("Paste your API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 10) {
                        Button("Save Key") { saveSecret(ref) }
                            .disabled(apiKeyInput.isEmpty)
                        if model.engine.secrets.has(ref) {
                            Label("Stored in Keychain (\(model.engine.secrets.fingerprint(ref) ?? ""))",
                                  systemImage: "checkmark.shield")
                                .font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    Text("Keys are written to the macOS Keychain, never to Derby's configuration file.")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .cli(let source, let allowRefresh):
                let signedIn = CLICredentialReader.isAvailable(source, home: draft?.credentialHomeURL)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: signedIn ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(signedIn ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cliStatus(source)).font(.callout)
                            Text("Read from \(cliOrigin(source))")
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    if let label = accountLabel(source) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            Text(label).font(.callout.weight(.medium)).textSelection(.enabled)
                        }
                    }

                    if CLICredentialReader.homeEnvironmentVariable(for: source) != nil {
                        credentialHomeSection(source)
                    }

                    Toggle("Let Derby refresh the token when it expires", isOn: Binding(
                        get: { allowRefresh },
                        set: { newValue in
                            draft?.auth = .cli(source: source, allowRefresh: newValue)
                            save()
                        }))
                    Text(allowRefresh
                         ? "Derby will renew the session itself and write the rotated token back so \(source.displayName) keeps working."
                         : "Derby only reads the credential. If it expires, run `\(source.loginCommand)` in Terminal.")
                        .font(.caption).foregroundStyle(.secondary)
                }

            case .awsSigV4(let accessRef, let secretRef, _, _):
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("AWS access key ID", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    Button("Save Access Key ID") { saveSecret(accessRef) }
                        .disabled(apiKeyInput.isEmpty)
                    Text(model.engine.secrets.has(accessRef) ? "Access key stored." : "No access key stored.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    SecureField("AWS secret access key", text: $secretInput)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                    Button("Save Secret Key") { saveSecret(secretRef, value: secretInput) }
                        .disabled(secretInput.isEmpty)
                    Text(model.engine.secrets.has(secretRef) ? "Secret key stored." : "No secret key stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @State private var secretInput = ""
    @State private var homeInput = ""

    /// Lets one account point at an isolated CLI state directory, which is how
    /// several logins to the *same* service run side by side.
    @ViewBuilder
    private func credentialHomeSection(_ source: CLICredentialSource) -> some View {
        let variable = CLICredentialReader.homeEnvironmentVariable(for: source) ?? ""
        let homes = LocalDiscovery.alternateHomes(for: source)
        let conflict = conflictingAccount(source)

        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Account directory").font(.callout.weight(.medium))
            Text("Each \(source.displayName) login lives in its own directory. Point separate Derby providers at separate directories to use more than one account at the same time.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { draft?.credentialHomeOverride ?? "" },
                set: { newValue in
                    draft?.credentialHomeOverride = newValue.isEmpty ? nil : newValue
                    homeInput = newValue
                    save()
                })) {
                Text("Default (\(CLICredentialReader.defaultHome(for: source).path))").tag("")
                ForEach(homes.filter { !$0.isDefault }) { home in
                    Text(home.accountLabel.map { "\($0) — \(home.path)" } ?? home.path).tag(home.path)
                }
                if let current = draft?.credentialHomeOverride, !current.isEmpty,
                   !homes.contains(where: { $0.path == current }) {
                    Text(current).tag(current)
                }
            }
            .labelsHidden()

            HStack(spacing: 8) {
                TextField("Or type a directory, e.g. ~/.codex-work", text: $homeInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        let trimmed = homeInput.trimmingCharacters(in: .whitespaces)
                        draft?.credentialHomeOverride = trimmed.isEmpty ? nil : trimmed
                        save()
                    }
                Button("Choose…") { chooseHome() }
            }

            if let conflict {
                Label("\(conflict) already uses this directory, so both providers would share one login.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if !signedInAt(source, home: draft?.credentialHomeURL) {
                let target = (draft?.credentialHomeURL ?? CLICredentialReader.defaultHome(for: source)).path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign this account in:").font(.caption).foregroundStyle(.secondary)
                    let command = "mkdir -p \(target) && \(variable)=\(target) \(source.loginCommand)"
                    HStack {
                        Text(command)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        Button {
                            model.copyToPasteboard(command, label: "Command")
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func signedInAt(_ source: CLICredentialSource, home: URL?) -> Bool {
        CLICredentialReader.isAvailable(source, home: home)
    }

    private func accountLabel(_ source: CLICredentialSource) -> String? {
        (try? CLICredentialReader.read(source, home: draft?.credentialHomeURL))?.accountLabel
    }

    /// Another provider already reading the same credential directory.
    private func conflictingAccount(_ source: CLICredentialSource) -> String? {
        guard let draft else { return nil }
        let mine = draft.credentialHomeURL?.path
            ?? CLICredentialReader.defaultHome(for: source).path
        return model.config.providers.first { other in
            guard other.id != draft.id, other.auth.describesCLI == source else { return false }
            let theirs = other.credentialHomeURL?.path
                ?? CLICredentialReader.defaultHome(for: source).path
            return theirs == mine
        }?.name
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the CLI state directory for this account"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        homeInput = url.path
        draft?.credentialHomeOverride = url.path
        save()
    }

    /// The store the credential was actually read from — Claude Code keeps
    /// its session in the Keychain on macOS, and may leave a stale file behind.
    private func cliOrigin(_ source: CLICredentialSource) -> String {
        let home = draft?.credentialHomeURL
        return (try? CLICredentialReader.read(source, home: home))?.origin
            ?? CLICredentialReader.credentialPath(for: source, home: home).path
    }

    private func cliStatus(_ source: CLICredentialSource) -> String {
        do {
            let cred = try CLICredentialReader.read(source, home: draft?.credentialHomeURL)
            return "\(source.displayName) is signed in · token \(cred.expiresInDescription)"
        } catch let e as DerbyError {
            return e.message
        } catch {
            return "Not signed in. Run `\(source.loginCommand)`."
        }
    }

    private func modelsCard(_ current: ProviderAccount) -> some View {
        Card(title: "Models", subtitle: "\(current.models.count) configured", systemImage: "cube") {
            VStack(alignment: .leading, spacing: 10) {
                if current.models.isEmpty {
                    Text("No models yet. Use Discover Models, or add one by name.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(current.models) { physical in
                    ModelRow(account: current, physical: physical,
                             health: model.health(providerID: current.id, modelID: physical.modelID),
                             isProbing: probingModel == physical.modelID,
                             onToggle: { enabled in
                                 updateModel(physical.id) { $0.enabled = enabled }
                             },
                             onQuality: { quality in
                                 updateModel(physical.id) { $0.qualityScore = quality }
                             },
                             onCapabilities: { flags in
                                 updateModel(physical.id) { $0.capabilityOverrides.flags = flags }
                             },
                             onContext: { window in
                                 updateModel(physical.id) { $0.capabilityOverrides.contextWindow = window }
                             },
                             onPricing: { pricing in
                                 updateModel(physical.id) { $0.pricingOverride = pricing }
                             },
                             onProbe: { Task { await probe(physical.modelID) } },
                             onRemove: { removeModel(physical.id) },
                             onResetCircuit: {
                                 Task {
                                     await model.engine.resetCircuit(
                                        TargetKey(providerID: current.id, modelID: physical.modelID))
                                     await model.refreshLive()
                                 }
                             })
                }

                HStack {
                    TextField("Add a model by name (e.g. gpt-5.1)", text: $modelToAdd)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addModel(current) }
                    Button("Add") { addModel(current) }
                        .disabled(modelToAdd.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func limitsCard(_ current: ProviderAccount) -> some View {
        Card(title: "Limits & timeouts", subtitle: "Derby enforces these before contacting the provider",
             systemImage: "speedometer") {
            AdaptiveGrid(minWidth: 210) {
                NumberField(label: "Request timeout (s)", value: binding(\.requestTimeoutSeconds),
                            range: 5...1800, onCommit: save)
                NumberField(label: "Max concurrent requests",
                            value: intBinding(\.rateLimits.maxConcurrentRequests),
                            range: 1...64, onCommit: save)
                OptionalNumberField(label: "Requests / minute",
                                    value: optionalIntBinding(\.rateLimits.requestsPerMinute), onCommit: save)
                OptionalNumberField(label: "Tokens / minute",
                                    value: optionalIntBinding(\.rateLimits.tokensPerMinute), onCommit: save)
                OptionalNumberField(label: "Daily request quota",
                                    value: optionalIntBinding(\.rateLimits.dailyRequestQuota), onCommit: save)
                OptionalDoubleField(label: "Monthly budget (USD)",
                                    value: optionalDoubleBinding(\.rateLimits.monthlyCostBudgetUSD), onCommit: save)
            }
        }
    }

    private func advancedCard(_ current: ProviderAccount) -> some View {
        Card(title: "Advanced", systemImage: "gearshape.2") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider preference: \(Int(current.preferenceScore))")
                        .font(.callout)
                    Slider(value: binding(\.preferenceScore), in: 0...100, step: 5) { editing in
                        if !editing { save() }
                    }
                    Text("Used by the weighted-score strategy when a logical model gives provider preference a weight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Allow self-signed TLS certificates", isOn: binding(\.allowInsecureTLS))
                    .onChange(of: current.allowInsecureTLS) { _, _ in save() }
                if current.allowInsecureTLS {
                    Label("Only enable this for a private server you control.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HeaderEditor(headers: binding(\.extraHeaders), onCommit: save)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.callout)
                    TextEditor(text: binding(\.notes))
                        .font(.callout)
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                        .onChange(of: current.notes) { _, _ in save() }
                }
            }
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<ProviderAccount, T>) -> Binding<T> {
        Binding(get: { draft?[keyPath: keyPath] ?? account![keyPath: keyPath] },
                set: { draft?[keyPath: keyPath] = $0 })
    }
    private func optionalBinding(_ keyPath: WritableKeyPath<ProviderAccount, String?>) -> Binding<String> {
        Binding(get: { draft?[keyPath: keyPath] ?? "" },
                set: { draft?[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    private func intBinding(_ keyPath: WritableKeyPath<ProviderAccount, Int>) -> Binding<Int> {
        Binding(get: { draft?[keyPath: keyPath] ?? 0 }, set: { draft?[keyPath: keyPath] = $0 })
    }
    private func optionalIntBinding(_ keyPath: WritableKeyPath<ProviderAccount, Int?>) -> Binding<Int?> {
        Binding(get: { draft?[keyPath: keyPath] ?? nil }, set: { draft?[keyPath: keyPath] = $0 })
    }
    private func optionalDoubleBinding(_ keyPath: WritableKeyPath<ProviderAccount, Double?>) -> Binding<Double?> {
        Binding(get: { draft?[keyPath: keyPath] ?? nil }, set: { draft?[keyPath: keyPath] = $0 })
    }

    // MARK: - Actions

    private func save() {
        guard let draft else { return }
        Task {
            await model.mutate { config in
                if let index = config.providers.firstIndex(where: { $0.id == draft.id }) {
                    config.providers[index] = draft
                }
            }
        }
    }

    private func saveSecret(_ ref: SecretRef, value: String? = nil) {
        let secret = value ?? apiKeyInput
        do {
            try model.engine.secrets.set(secret, for: ref)
            model.show(.success, "Credential saved to Keychain")
            if value == nil { apiKeyInput = secret }
        } catch {
            model.show(.error, "Could not save the credential", error.localizedDescription)
        }
    }

    private func delete() {
        guard let account else { return }
        Task {
            for ref in account.auth.secretRefs { try? model.engine.secrets.delete(ref) }
            await model.mutate("Removed \(account.name)") { config in
                config.providers.removeAll { $0.id == account.id }
                for i in config.logicalModels.indices {
                    config.logicalModels[i].targets.removeAll { $0.providerID == account.id }
                }
            }
        }
    }

    private func test() async {
        guard let draft else { return }
        isTesting = true
        defer { isTesting = false }
        save()
        testResult = await model.engine.testConnection(draft)
    }

    private func discover() async {
        guard let draft else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        save()
        do {
            let found = try await model.engine.discoverModels(draft)
            importModels(found)
        } catch let e as DerbyError {
            testResult = .failure(e)
        } catch {
            model.show(.error, "Discovery failed", error.localizedDescription)
        }
    }

    private func importModels(_ found: [DiscoveredModel]) {
        guard var current = draft else { return }
        let existing = Set(current.models.map(\.modelID))
        let discovered = Set(found.map(\.id))
        let additions = found.filter { !existing.contains($0.id) }

        for item in additions {
            current.models.append(ProviderFactory.makeModel(id: item.id, kind: current.kind, discovered: item))
        }

        // Refresh capability metadata on models that already existed, so a
        // re-discovery picks up newly reported features.
        for item in found {
            guard let index = current.models.firstIndex(where: { $0.modelID == item.id }),
                  let caps = item.capabilities else { continue }
            current.models[index].capabilities = caps
            if current.models[index].displayName == nil { current.models[index].displayName = item.displayName }
        }

        // For providers whose catalog is definitive, drop models the account can
        // no longer use — otherwise a retired model sits there and fails.
        var removed: [String] = []
        if current.kind.hasAuthoritativeCatalog {
            let stale = current.models.filter { !discovered.contains($0.modelID) }
            removed = stale.map(\.modelID)
            let staleIDs = Set(stale.map(\.id))
            current.models.removeAll { staleIDs.contains($0.id) }
            if !staleIDs.isEmpty {
                Task {
                    await model.mutate { config in
                        for i in config.logicalModels.indices {
                            config.logicalModels[i].targets.removeAll { staleIDs.contains($0.modelUUID) }
                        }
                    }
                }
            }
        }

        draft = current
        save()

        var parts: [String] = []
        if !additions.isEmpty { parts.append("added \(additions.count)") }
        if !removed.isEmpty { parts.append("removed \(removed.count) no longer offered") }
        model.show(.success,
                   parts.isEmpty ? "Model list is up to date" : "Models updated",
                   parts.isEmpty ? nil : parts.joined(separator: ", ")
                       + (removed.isEmpty ? "" : " (\(removed.joined(separator: ", ")))"))
        testResult = nil
    }

    private func probe(_ modelID: String) async {
        guard let draft else { return }
        probingModel = modelID
        defer { probingModel = nil }
        testResult = await model.engine.probeModel(account: draft, modelID: modelID)
    }

    private func addModel(_ current: ProviderAccount) {
        let name = modelToAdd.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !current.models.contains(where: { $0.modelID == name }) else {
            model.show(.warning, "\(name) is already configured")
            return
        }
        draft?.models.append(ProviderFactory.makeModel(id: name, kind: current.kind))
        modelToAdd = ""
        save()
    }

    private func removeModel(_ id: UUID) {
        draft?.models.removeAll { $0.id == id }
        save()
        Task {
            await model.mutate { config in
                for i in config.logicalModels.indices {
                    config.logicalModels[i].targets.removeAll { $0.modelUUID == id }
                }
            }
        }
    }

    private func updateModel(_ id: UUID, _ body: (inout PhysicalModel) -> Void) {
        guard let index = draft?.models.firstIndex(where: { $0.id == id }) else { return }
        body(&draft!.models[index])
        save()
    }
}
