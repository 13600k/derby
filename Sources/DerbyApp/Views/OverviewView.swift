import SwiftUI
import DerbyCore

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        Page(title: "Overview", subtitle: "One endpoint outward. Many providers inward.") {
            Button {
                Task {
                    await model.refreshAll()
                    await model.refreshProviderUsage()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !model.startupWarnings.isEmpty { warnings }
                gatewayCard
                statsRow
                discoveries
                HStack(alignment: .top, spacing: 16) {
                    logicalModelsCard.frame(maxWidth: .infinity)
                    providerHealthCard.frame(maxWidth: .infinity)
                }
                if !model.unavailableProviders.isEmpty { unavailableCard }
            }
        }
        .task { await model.refreshUsage() }
    }

    // MARK: - Gateway

    private var gatewayCard: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(model.status.tint).frame(width: 10, height: 10)
                        Text(headline).font(.title3.weight(.semibold))
                        if model.routingPaused && model.status.isRunning {
                            StatusPill(text: "ROUTING PAUSED", tint: .orange, systemImage: "pause.fill")
                        }
                    }
                    if let detail = model.status.detail {
                        Text(detail).font(.callout).foregroundStyle(.red)
                    }

                    CopyableField(label: "OpenAI-compatible base URL", value: model.endpoint) {
                        model.copyToPasteboard($0, label: "Endpoint")
                    }
                    .frame(maxWidth: 420)

                    if model.config.gateway.requireAPIKey {
                        CopyableField(label: "Local API key", value: model.localKey, isSecret: true) {
                            model.copyToPasteboard($0, label: "API key")
                        }
                        .frame(maxWidth: 420)
                    } else if model.config.gateway.isReachableOffThisMac {
                        Label("Reachable from your network with no API key", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Label("No API key needed — the base URL is all a client needs", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    if model.status.isRunning {
                        Button {
                            Task { await model.restartGateway() }
                        } label: {
                            Label("Restart Gateway", systemImage: "arrow.clockwise")
                                .frame(width: 150, alignment: .leading)
                        }
                        Button {
                            Task { await model.stopGateway() }
                        } label: {
                            Label("Stop Gateway", systemImage: "stop.fill")
                                .frame(width: 150, alignment: .leading)
                        }
                        Button {
                            Task { await model.toggleRoutingPaused() }
                        } label: {
                            Label(model.routingPaused ? "Resume Routing" : "Pause Routing",
                                  systemImage: model.routingPaused ? "play.fill" : "pause.fill")
                                .frame(width: 150, alignment: .leading)
                        }
                    } else {
                        Button {
                            Task { await model.startGateway() }
                        } label: {
                            Label("Start Gateway", systemImage: "play.fill")
                                .frame(width: 150, alignment: .leading)
                        }
                        .derbyProminentButton()
                    }
                }
            }
        }
    }

    private var headline: String {
        switch model.status {
        case .running(let port, let since):
            return "Gateway running on port \(port) · up \(Format.relative(since).replacingOccurrences(of: " ago", with: ""))"
        case .starting: return "Gateway starting…"
        case .stopped: return "Gateway stopped"
        case .failed: return "Gateway failed to start"
        }
    }

    private var warnings: some View {
        Card(title: "Startup notes", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.startupWarnings.enumerated()), id: \.offset) { _, warning in
                    Text("• \(warning)").font(.callout).foregroundStyle(.secondary)
                }
                Button("Dismiss") { model.startupWarnings = [] }
                    .buttonStyle(.link)
            }
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        AdaptiveGrid(minWidth: 165) {
            StatTile(label: "Requests today", value: Format.count(model.usage.totalRequests),
                     caption: model.usage.failures > 0 ? "\(model.usage.failures) failed" : "all succeeded",
                     systemImage: "arrow.left.arrow.right")
            StatTile(label: "Success rate",
                     value: model.usage.totalRequests == 0 ? "—" : Format.percent(model.usage.successRate),
                     caption: "rolling, today",
                     tint: successTint, systemImage: "checkmark.seal")
            StatTile(label: "Failovers", value: Format.count(model.usage.failovers),
                     caption: "\(model.usage.retries) retries", systemImage: "arrow.triangle.branch")
            StatTile(label: "Estimated cost", value: model.usage.costUSD.usdString,
                     caption: "\(Format.count(model.usage.inputTokens + model.usage.outputTokens)) tokens",
                     systemImage: "dollarsign.circle")
            StatTile(label: "Avg latency", value: Format.latency(model.usage.avgLatency),
                     caption: model.usage.avgTTFT.map { "TTFT \(Format.latency($0))" } ?? "no TTFT samples",
                     systemImage: "timer")
        }
    }

    private var successTint: Color {
        guard model.usage.totalRequests > 0 else { return .primary }
        if model.usage.successRate >= 0.98 { return .green }
        if model.usage.successRate >= 0.85 { return .orange }
        return .red
    }

    // MARK: - Logical models

    private var logicalModelsCard: some View {
        Card(title: "Active logical models",
             subtitle: "Names your applications ask for", systemImage: "square.stack.3d.up") {
            if model.activeLogicalModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No logical model has a usable target yet.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Set up logical models") { selection = .logicalModels }
                        .buttonStyle(.link)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(model.activeLogicalModels, id: \.name) { lm in
                        Button {
                            selection = .logicalModels
                        } label: {
                            HStack(spacing: 10) {
                                Text(lm.name)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                StatusPill(text: lm.definition.policy.strategy.displayName.uppercased(),
                                           tint: .derbyAccent)
                                Spacer()
                                Text("\(usableCount(lm)) of \(lm.targets.count) target\(lm.targets.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .rowStyle()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func usableCount(_ lm: ResolvedLogicalModel) -> Int {
        lm.targets.filter { target in
            target.unavailableReason == nil && model.health(for: target).circuit != .open
        }.count
    }

    // MARK: - Providers

    private var providerHealthCard: some View {
        Card(title: "Provider health", subtitle: "Live target state and plan usage", systemImage: "server.rack") {
            if model.config.providers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No providers configured yet.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Add your first provider") { selection = .providers }
                        .buttonStyle(.link)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(model.providerHealthSummaries) { summary in
                        Button { selection = .providers } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Image(systemName: summary.worstState.symbol)
                                        .foregroundStyle(summary.account.enabled ? summary.worstState.tint : .secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(summary.account.name).font(.callout.weight(.medium))
                                        Text(summary.account.kind.displayName)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if summary.usage?.usage?.isLimited == true {
                                        StatusPill(text: "LIMIT REACHED", tint: .red)
                                    }
                                    Text(summary.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                if let usage = summary.usage {
                                    PlanUsageView(status: usage)
                                        .padding(.leading, 26)
                                }
                            }
                            .rowStyle()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var unavailableCard: some View {
        Card(title: "Currently unavailable", systemImage: "exclamationmark.triangle") {
            VStack(spacing: 6) {
                ForEach(model.unavailableProviders) { summary in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(summary.account.name).font(.callout.weight(.medium))
                        Spacer()
                        Text(summary.detail).font(.caption).foregroundStyle(.secondary)
                        if summary.openCircuits > 0 {
                            Button("Reset circuits") {
                                Task {
                                    for m in summary.account.models {
                                        await model.engine.resetCircuit(
                                            TargetKey(providerID: summary.account.id, modelID: m.modelID))
                                    }
                                    await model.refreshLive()
                                    model.show(.success, "Circuits reset for \(summary.account.name)")
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .rowStyle()
                }
            }
        }
    }

    // MARK: - Discovery

    @ViewBuilder
    private var discoveries: some View {
        if !model.unconfiguredLocalFindings.isEmpty || !model.unconfiguredSubscriptions.isEmpty {
            Card(title: "Detected on this Mac",
                 subtitle: "Derby found these and can set them up for you",
                 systemImage: "sparkle.magnifyingglass") {
                VStack(spacing: 6) {
                    ForEach(model.unconfiguredSubscriptions) { finding in
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.key").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.kind.displayName).font(.callout.weight(.medium))
                                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") {
                                Task { await ProviderFactory.addSubscription(finding, model: model) }
                            }
                        }
                        .rowStyle()
                    }
                    ForEach(model.unconfiguredLocalFindings) { finding in
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer").foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.kind.displayName).font(.callout.weight(.medium))
                                Text("\(finding.baseURL) · \(finding.note)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import") {
                                Task { await ProviderFactory.addLocalServer(finding, model: model) }
                            }
                        }
                        .rowStyle()
                    }
                }
            }
        }
    }
}
