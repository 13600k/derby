import SwiftUI
import DerbyCore

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: SidebarItem?

    @State private var step = 0

    private var steps: [Step] { Step.allCases }

    enum Step: Int, CaseIterable {
        case welcome, gateway, providers, models, test

        var title: String {
            switch self {
            case .welcome: return "Welcome to Derby"
            case .gateway: return "Start the local gateway"
            case .providers: return "Add a provider"
            case .models: return "Group models into logical models"
            case .test: return "Point a client at Derby"
            }
        }
        var symbol: String {
            switch self {
            case .welcome: return "flag.checkered"
            case .gateway: return "network"
            case .providers: return "server.rack"
            case .models: return "square.stack.3d.up"
            case .test: return "terminal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: steps[step].symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(steps[step].title).font(.title2.weight(.semibold))
                Text("Step \(step + 1) of \(steps.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: index == step ? 18 : 7, height: 5)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch steps[step] {
        case .welcome: welcomeStep
        case .gateway: gatewayStep
        case .providers: providersStep
        case .models: modelsStep
        case .test: testStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Derby is a local AI routing gateway. Your applications talk to one endpoint; Derby decides which provider actually answers.")
                .font(.title3)
            VStack(alignment: .leading, spacing: 10) {
                bullet("square.stack.3d.up", "Logical models",
                       "Ask for a name like `coding` instead of a provider model. Derby resolves it to a ranked list of real targets.")
                bullet("arrow.triangle.branch", "A policy per logical model",
                       "`smart` can chase quality while `cheap` chases price — they are independent.")
                bullet("bolt.heart", "Failures are routine",
                       "Retries, failover, circuit breakers and budgets are built in, and every decision is explained afterwards.")
                bullet("person.badge.key", "Use what you already pay for",
                       "Metered APIs, subscription accounts, local servers and any OpenAI-compatible endpoint are all the same kind of target.")
            }
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var gatewayStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Derby runs the gateway itself — there is no separate process to start.")
                .font(.callout)
            Card {
                HStack(spacing: 12) {
                    Circle().fill(model.status.tint).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.status.displayName).font(.headline)
                        Text(model.endpoint).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.status.isRunning {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                    } else {
                        Button("Start Gateway") { Task { await model.startGateway() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            if model.config.gateway.requireAPIKey {
                CopyableField(label: "Local API key — clients must send this", value: model.localKey, isSecret: true) {
                    model.copyToPasteboard($0, label: "API key")
                }
            }
            Text("The gateway binds to 127.0.0.1 only, so nothing outside this Mac can reach it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providersStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Derby needs at least one place to send requests.")
                .font(.callout)

            if !model.subscriptionFindings.filter(\.available).isEmpty {
                Card(title: "Subscriptions you are already signed in to", systemImage: "person.badge.key") {
                    VStack(spacing: 6) {
                        ForEach(model.subscriptionFindings.filter(\.available)) { finding in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(finding.kind.displayName).font(.callout.weight(.medium))
                                    Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.config.providers.contains(where: { $0.kind == finding.kind }) {
                                    StatusPill(text: "ADDED", tint: .green)
                                } else {
                                    Button("Add") { Task { await ProviderFactory.addSubscription(finding, model: model) } }
                                }
                            }
                            .rowStyle()
                        }
                    }
                }
            }

            if !model.localFindings.isEmpty {
                Card(title: "Local model servers running now", systemImage: "desktopcomputer") {
                    VStack(spacing: 6) {
                        ForEach(model.localFindings) { finding in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(finding.kind.displayName).font(.callout.weight(.medium))
                                    Text("\(finding.baseURL) · \(finding.note)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.config.providers.contains(where: { $0.baseURL == finding.baseURL.trimmedTrailingSlash }) {
                                    StatusPill(text: "ADDED", tint: .green)
                                } else {
                                    Button("Import") { Task { await ProviderFactory.addLocalServer(finding, model: model) } }
                                }
                            }
                            .rowStyle()
                        }
                    }
                }
            }

            Card(title: "Anything else", systemImage: "plus.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add an API key provider (OpenAI, Anthropic, Gemini, Groq, OpenRouter…) or any custom OpenAI-compatible endpoint from the Providers screen.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Providers") {
                        selection = .providers
                        finish()
                    }
                }
            }

            if model.config.providers.isEmpty {
                Label("No providers configured yet — you can skip this and come back later.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("\(model.config.providers.count) provider\(model.config.providers.count == 1 ? "" : "s") configured.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .task { await model.scanForLocalServers() }
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Derby ships with five starter groups. They are ordinary templates — rename them, delete them, or add your own.")
                .font(.callout)
            Card {
                VStack(spacing: 6) {
                    ForEach(model.config.logicalModels) { lm in
                        HStack(spacing: 10) {
                            Text(lm.name)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 74, alignment: .leading)
                            StatusPill(text: lm.policy.strategy.displayName.uppercased(), tint: .accentColor)
                            Text(lm.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(lm.targets.count) target\(lm.targets.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(lm.targets.isEmpty ? .orange : .secondary)
                        }
                        .rowStyle()
                    }
                }
            }
            Text("Each one carries its own strategy, retry rules, timeouts and budget. Add targets to them in Logical Models.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Logical Models") {
                selection = .logicalModels
                finish()
            }
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Point any OpenAI-compatible client at Derby.")
                .font(.callout)
            Card(title: "Client configuration", systemImage: "doc.on.clipboard") {
                VStack(alignment: .leading, spacing: 10) {
                    CopyableField(label: "Base URL", value: model.endpoint) {
                        model.copyToPasteboard($0, label: "Base URL")
                    }
                    if model.config.gateway.requireAPIKey {
                        CopyableField(label: "API key", value: model.localKey, isSecret: true) {
                            model.copyToPasteboard($0, label: "API key")
                        }
                    }
                    CopyableField(label: "Model", value: model.config.logicalModels.first?.name ?? "coding") {
                        model.copyToPasteboard($0, label: "Model")
                    }
                }
            }
            Card(title: "Try it from Terminal", systemImage: "terminal") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(curlExample)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    Button("Copy command") { model.copyToPasteboard(curlExample, label: "Command") }
                        .buttonStyle(.link)
                }
            }
            Text("Or use the built-in Test Console, which runs the same routing and execution path.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var curlExample: String {
        let modelName = model.config.logicalModels.first?.name ?? "coding"
        let auth = model.config.gateway.requireAPIKey
            ? "\n  -H \"Authorization: Bearer \(model.localKey)\" \\"
            : ""
        return """
        curl \(model.endpoint)/chat/completions \\
          -H "Content-Type: application/json" \\\(auth)
          -d '{
            "model": "\(modelName)",
            "messages": [{"role": "user", "content": "Explain CAP theorem."}]
          }'
        """
    }

    private var footer: some View {
        HStack {
            Button("Skip") { finish() }
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Button(step == steps.count - 1 ? "Finish" : "Next") {
                if step == steps.count - 1 { finish() } else { step += 1 }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func finish() {
        Task { await model.completeOnboarding() }
        dismiss()
    }
}
