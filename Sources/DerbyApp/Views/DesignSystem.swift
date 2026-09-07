import SwiftUI
import DerbyCore

// MARK: - Colors

extension HealthState {
    var tint: Color {
        switch self {
        case .healthy: return .green
        case .degraded: return .orange
        case .unhealthy: return .red
        case .disabled: return .secondary
        case .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unhealthy: return "xmark.octagon.fill"
        case .disabled: return "minus.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension CircuitState {
    var tint: Color {
        switch self {
        case .closed: return .green
        case .halfOpen: return .orange
        case .open: return .red
        }
    }
}

extension GatewayStatus {
    var tint: Color {
        switch self {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

extension FailureKind {
    var tint: Color {
        switch self {
        case .invalidRequest, .contentPolicy, .capabilityMismatch: return .orange
        case .clientCancelled: return .secondary
        default: return .red
        }
    }
}

extension ProviderCategory {
    var symbol: String {
        switch self {
        case .api: return "cloud"
        case .subscription: return "person.badge.key"
        case .local: return "desktopcomputer"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - Building blocks

/// A titled container used for every grouped block in the app.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.headline)
                        }
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

/// A headline metric.
struct StatTile: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color = .primary
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

struct StatusPill: View {
    var text: String
    var tint: Color
    var systemImage: String?
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.3)
        }
        .foregroundStyle(filled ? .white : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        // A filled pill still needs a solid ground under white text; an unfilled
        // one is a chip of glass stained in its own status colour.
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear), in: Capsule())
        .glassSurface(.chip, in: Capsule(), tint: tint)
    }
}

/// Monospaced value with a copy button — used for endpoints, keys and ids.
struct CopyableField: View {
    var label: String?
    var value: String
    var isSecret = false
    var onCopy: (String) -> Void
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(displayValue)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSecret {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealed ? "Hide" : "Reveal")
                }
                Button {
                    onCopy(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassSurface(.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var displayValue: String {
        guard isSecret, !revealed, !value.isEmpty else { return value }
        return String(value.prefix(10)) + String(repeating: "•", count: max(6, min(24, value.count - 10)))
    }
}

/// Left-aligned label, right-aligned value.
struct DetailRow: View {
    var label: String
    var value: String
    var tint: Color = .primary
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .callout)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Empty-state placeholder with an optional call to action.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .derbyProminentButton()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// A labelled proportion bar, used for routing weights and usage breakdowns.
struct WeightBar: View {
    var value: Double          // 0...1
    var tint: Color = .derbyAccent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// Standard page scaffold: title, optional toolbar content, scrolling body.
struct Page<Content: View, Toolbar: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var toolbar: Toolbar
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                toolbar
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The header is chrome, so it is stained hardest and carries the
            // seam that used to be a `Divider()`.
            .glassSurface(.chrome, in: Rectangle())

            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clearScrollBackground()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deliberately no fill: the page is a hole through to the window
        // backdrop, which is what the cards on top of it refract.
        .glassPane()
    }
}

extension Page where Toolbar == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, toolbar: { EmptyView() }, content: content)
    }
}

/// Two-column adaptive grid used across the dashboards.
struct AdaptiveGrid<Content: View>: View {
    var minWidth: CGFloat = 180
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        // On macOS 26 a container lets neighbouring glass pieces sense each
        // other: tiles that come within `spacing` fuse at the edges and pull
        // apart again as the grid reflows. That merging is the "liquid" half of
        // Liquid Glass, and it only happens inside a container.
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { grid }
        } else {
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: spacing)], spacing: spacing) {
            content
        }
    }
}

extension View {
    /// Applies a subtle inset-grouped look to list rows.
    func rowStyle() -> some View {
        padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glassSurface(.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                          interactive: true)
    }
}

// MARK: - Formatting

enum Format {
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }
    static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
    /// Token counts, prefixed with "≈" when Derby estimated them itself.
    static func tokens(_ n: Int, estimated: Bool) -> String {
        (estimated ? "≈" : "") + count(n)
    }
    static func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
    static func latency(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        return seconds.msString
    }
}
