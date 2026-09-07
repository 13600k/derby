import SwiftUI
import DerbyCore

struct UsageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Page(title: "Usage", subtitle: "Tokens, cost and reliability across every provider") {
            Picker("", selection: $model.usageWindow) {
                ForEach(UsageWindow.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .onChange(of: model.usageWindow) { _, _ in Task { await model.refreshUsage() } }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                totals
                if model.usage.totalRequests == 0 {
                    Card {
                        Text("No requests recorded in this window yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    if model.usage.daily.count > 1 { dailyChart }
                    HStack(alignment: .top, spacing: 16) {
                        breakdown("By logical model", model.usage.byLogicalModel, symbol: "square.stack.3d.up")
                        breakdown("By provider", model.usage.byProvider, symbol: "server.rack")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        breakdown("By physical model", model.usage.byPhysicalModel, symbol: "cube")
                        breakdown("By application", model.usage.byClient, symbol: "app.badge")
                    }
                }
                pricingNote
            }
        }
        .task { await model.refreshUsage() }
    }

    private var totals: some View {
        AdaptiveGrid(minWidth: 165) {
            StatTile(label: "Requests", value: Format.count(model.usage.totalRequests),
                     caption: "\(model.usage.failures) failed", systemImage: "arrow.left.arrow.right")
            StatTile(label: "Success rate",
                     value: model.usage.totalRequests == 0 ? "—" : Format.percent(model.usage.successRate),
                     caption: "\(model.usage.failovers) failovers", systemImage: "checkmark.seal")
            StatTile(label: "Input tokens", value: Format.count(model.usage.inputTokens),
                     caption: model.usage.cachedTokens > 0 ? "\(Format.count(model.usage.cachedTokens)) cached" : "no cache hits",
                     systemImage: "arrow.down.doc")
            StatTile(label: "Output tokens", value: Format.count(model.usage.outputTokens),
                     caption: model.usage.reasoningTokens > 0 ? "\(Format.count(model.usage.reasoningTokens)) reasoning" : "—",
                     systemImage: "arrow.up.doc")
            StatTile(label: "Estimated cost", value: model.usage.costUSD.usdString,
                     caption: "priced targets only", systemImage: "dollarsign.circle")
            StatTile(label: "Avg latency", value: Format.latency(model.usage.avgLatency),
                     caption: model.usage.avgTTFT.map { "TTFT \(Format.latency($0))" } ?? "—",
                     systemImage: "timer")
        }
    }

    private var dailyChart: some View {
        Card(title: "Requests per day", systemImage: "chart.bar") {
            let maxValue = max(1, model.usage.daily.map(\.requests).max() ?? 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(model.usage.daily) { bucket in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.derbyAccent.opacity(0.15))
                                .frame(height: 90)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.derbyAccent)
                                .frame(height: max(2, 90 * CGFloat(bucket.requests) / CGFloat(maxValue)))
                        }
                        Text(String(bucket.key.suffix(5)))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(-45))
                            .frame(height: 20)
                    }
                    .help("\(bucket.key): \(bucket.requests) requests, \(bucket.costUSD.usdString)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func breakdown(_ title: String, _ buckets: [UsageBucket], symbol: String) -> some View {
        Card(title: title, systemImage: symbol) {
            if buckets.isEmpty {
                Text("No data").font(.callout).foregroundStyle(.secondary)
            } else {
                let total = max(1, buckets.reduce(0) { $0 + $1.requests })
                VStack(spacing: 8) {
                    ForEach(buckets.prefix(8)) { bucket in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(bucket.key)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(bucket.requests)")
                                    .font(.caption.monospacedDigit())
                                if bucket.costUSD > 0 {
                                    Text(bucket.costUSD.usdString)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            WeightBar(value: Double(bucket.requests) / Double(total))
                            HStack(spacing: 10) {
                                Text("\(Format.percent(bucket.successRate)) ok")
                                Text("\(Format.count(bucket.inputTokens)) in / \(Format.count(bucket.outputTokens)) out")
                                Text(Format.latency(bucket.avgLatency))
                            }
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var pricingNote: some View {
        Card(title: "About these numbers", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Cost is an estimate from bundled list prices and any per-model overrides you set. Local models and subscription-backed accounts are treated as zero marginal cost, because you have already paid for them.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Targets with unknown pricing contribute tokens but no cost — Derby never blocks routing on missing price metadata.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
