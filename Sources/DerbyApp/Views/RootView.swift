import SwiftUI
import DerbyCore

/// A destination in the sidebar.
///
/// Deliberately *not* called `Section`: that shadows `SwiftUI.Section`, and the
/// shadowing is what let `List(selection:)` silently resolve its selection type
/// to `Section?` while rows were tagged `Section` — so no row was selectable.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, logicalModels, providers, routing, console, requests, usage, logs, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logicalModels: return "Logical Models"
        case .providers: return "Providers"
        case .routing: return "Routing"
        case .console: return "Test Console"
        case .requests: return "Requests"
        case .usage: return "Usage"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .logicalModels: return "square.stack.3d.up"
        case .providers: return "server.rack"
        case .routing: return "arrow.triangle.branch"
        case .console: return "terminal"
        case .requests: return "list.bullet.rectangle"
        case .usage: return "chart.bar"
        case .logs: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }

    struct SidebarGroup: Identifiable {
        var id: String { title.isEmpty ? items.map(\.rawValue).joined() : title }
        var title: String
        var items: [SidebarItem]
    }

    // Named `SidebarGroup`, not `Group`, so it cannot shadow `SwiftUI.Group`.
    static let groups: [SidebarGroup] = [
        SidebarGroup(title: "", items: [.overview]),
        SidebarGroup(title: "Configure", items: [.logicalModels, .providers, .routing]),
        SidebarGroup(title: "Operate", items: [.console, .requests, .usage, .logs]),
        SidebarGroup(title: "", items: [.settings]),
    ]

    /// Every case must appear in exactly one group, or it is unreachable.
    static var allGrouped: [SidebarItem] { groups.flatMap(\.items) }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    // Single-selection `List` binds `Binding<SelectionValue?>`; an optional here
    // is what makes rows tagged with `SidebarItem` actually selectable.
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack(alignment: .top) {
                detail
                if let banner = model.banner {
                    BannerView(banner: banner)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.banner)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView(selection: $selection)
                .environmentObject(model)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.groups) { group in
                if group.title.isEmpty {
                    ForEach(group.items) { item in row(item) }
                } else {
                    Section(group.title) {
                        ForEach(group.items) { item in row(item) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 208, max: 260)
        .safeAreaInset(edge: .bottom) { gatewayFooter }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        let count = badge(for: item)
        Label(item.title, systemImage: item.symbol)
            .badge(count > 0 ? Text("\(count)") : nil)
            .tag(item)
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .providers: return model.unavailableProviders.count
        default: return 0
        }
    }

    private var gatewayFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 7) {
                Circle()
                    .fill(model.status.tint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.routingPaused && model.status.isRunning ? "Routing paused" : model.status.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    if model.status.isRunning {
                        Text(model.endpoint)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if model.status.isRunning {
                    Button {
                        model.copyToPasteboard(model.endpoint, label: "Endpoint")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy endpoint")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview: OverviewView(selection: $selection)
        case .logicalModels: LogicalModelsView()
        case .providers: ProvidersView()
        case .routing: RoutingSimulatorView()
        case .console: ConsoleView()
        case .requests: RequestsView()
        case .usage: UsageView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}

struct BannerView: View {
    var banner: AppModel.Banner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.medium))
                if let detail = banner.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}
