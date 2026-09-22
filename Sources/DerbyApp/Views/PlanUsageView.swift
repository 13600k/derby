import SwiftUI
import DerbyCore

/// One account's plan meter: a bar per window, then any balance, then where
/// the figures came from — so Derby's own count is never read as the
/// provider's.
struct PlanUsageView: View {
    var status: ProviderUsageStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let usage = status.usage {
                if !usage.windows.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(usage.windows) { window in
                            GridRow {
                                Text(window.label)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(window.label)
                                    .frame(maxWidth: 150, alignment: .leading)
                                if let fraction = window.usedFraction {
                                    WeightBar(value: fraction, tint: Self.tint(window))
                                        .frame(minWidth: 50)
                                } else {
                                    Color.clear.frame(height: 6)
                                }
                                Text(Self.value(window))
                                    .monospacedDigit()
                                    .foregroundStyle(window.isExhausted ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                                    .gridColumnAlignment(.trailing)
                                Text(window.resetsAt.map(Self.resets) ?? "")
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    .font(.caption)
                }
                if !usage.amounts.isEmpty {
                    Text(usage.amounts.map { "\($0.label) \(Self.format($0.value, $0.unit))" }
                        .joined(separator: " · "))
                        .font(.caption).monospacedDigit()
                }
                Text(Self.provenance(usage, failed: status.error != nil))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(error)
            }
        }
    }

    // MARK: - Formatting

    static func tint(_ window: ProviderUsage.Window) -> Color {
        let f = window.usedFraction ?? 0
        if window.isExhausted || f >= 0.9 { return .red }
        if f >= 0.7 { return .orange }
        return .derbyAccent
    }

    static func value(_ window: ProviderUsage.Window) -> String {
        if let used = window.used, let limit = window.limit, let unit = window.unit {
            return "\(format(used, unit, compact: true)) / \(format(limit, unit, compact: true))"
        }
        if let fraction = window.usedFraction { return Format.percent(fraction) }
        if let used = window.used { return "\(Format.count(Int(used))) req" }
        return "—"
    }

    static func format(_ value: Double, _ unit: ProviderUsage.Unit, compact: Bool = false) -> String {
        switch unit {
        case .requests: return Format.count(Int(value)) + (compact ? "" : " req")
        case .usd: return value.usdString
        case .credits: return String(format: "%.2f", value)
        case .currency(let code):
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = code
            return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, code)
        }
    }

    /// "resets 2h 14m", to the minute when it is close and to the hour when not.
    static func resets(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 60 else { return "resetting" }
        let minutes = Int(seconds / 60)
        let (d, h, m) = (minutes / 1440, (minutes % 1440) / 60, minutes % 60)
        if d > 0 { return "resets \(d)d \(h)h" }
        if h > 0 { return "resets \(h)h \(m)m" }
        return "resets \(m)m"
    }

    static func provenance(_ usage: ProviderUsage, failed: Bool) -> String {
        var parts: [String] = []
        switch usage.source {
        case .provider:
            if let plan = usage.plan { parts.append(plan) }
            parts.append(failed ? "last read \(Format.relative(usage.observedAt))"
                                : "reported by the provider \(Format.relative(usage.observedAt))")
        case .counted:
            parts.append("Counted by Derby: successful requests it routed here, rolling windows")
        }
        return parts.joined(separator: " · ")
    }
}
