import SwiftUI
import DerbyCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: UUID?
    @State private var showAdd = false

    private var selected: ProviderAccount? {
        model.config.providers.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
            if let account = selected {
                ProviderDetailView(accountID: account.id)
                    .id(account.id)
            } else {
                EmptyStateView(systemImage: "server.rack",
                               title: "No provider selected",
                               message: "Pick a provider to configure its credentials, models and limits — or add a new account, endpoint or local server.",
                               actionTitle: "Add Provider") { showAdd = true }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProviderSheet { newID in selectedID = newID }
                .environmentObject(model)
        }
        .task {
            if selectedID == nil { selectedID = model.config.providers.first?.id }
            await model.scanForLocalServers()
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Providers").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    Task { await model.scanForLocalServers() }
                } label: {
                    Image(systemName: model.isScanning ? "arrow.triangle.2.circlepath" : "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Scan for local servers and signed-in CLIs")
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add a provider")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()

            List(selection: $selectedID) {
                ForEach(ProviderCategory.allCases, id: \.self) { category in
                    let items = model.config.providers.filter { $0.kind.category == category }
                    if !items.isEmpty {
                        SwiftUI.Section(category.displayName) {
                            ForEach(items) { account in
                                ProviderRow(account: account,
                                            summary: model.providerHealthSummaries.first { $0.id == account.id })
                                    .tag(account.id)
                            }
                        }
                    }
                }
                if model.config.providers.isEmpty {
                    Text("No providers yet").foregroundStyle(.secondary).font(.callout)
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProviderRow: View {
    var account: ProviderAccount
    var summary: ProviderHealthSummary?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: account.kind.category.symbol)
                .foregroundStyle(account.enabled ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(account.enabled ? .primary : .secondary)
                Text("\(account.kind.displayName) · \(account.models.filter(\.enabled).count) model\(account.models.filter(\.enabled).count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !account.enabled {
                StatusPill(text: "OFF", tint: .secondary)
            } else if let summary, summary.openCircuits > 0 {
                StatusPill(text: "\(summary.openCircuits)", tint: .red, systemImage: "bolt.slash")
            } else if let summary {
                Circle().fill(summary.worstState.tint).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
    }
}
