import SwiftUI
import DerbyCore

/// Shows a full routing decision: ranked candidates with scores, exclusions
/// with reasons, and the resulting attempt plan.
struct RoutingDecisionCard: View {
    var decision: RoutingDecision
    var onDismiss: (() -> Void)?

    var body: some View {
        Card(title: "Expected route",
             subtitle: "\(decision.strategy.displayName) · \(decision.logicalModelName)",
             systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 12) {
                if let onDismiss {
                    HStack {
                        Spacer()
                        Button { onDismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.top, -30)
                }

                if let winner = decision.evaluations.first {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(winner.targetLabel).font(.headline)
                            Text(decision.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if !decision.evaluations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ranked candidates").font(.caption).foregroundStyle(.secondary)
                        ForEach(decision.evaluations, id: \.rank) { evaluation in
                            CandidateRow(evaluation: evaluation, maxScore: decision.evaluations.first?.score ?? 1)
                        }
                    }
                }

                if !decision.exclusions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Excluded").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(decision.exclusions.enumerated()), id: \.offset) { _, exclusion in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(exclusion.targetLabel).font(.callout)
                                    Text(exclusion.reason).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusPill(text: exclusion.stage.displayName.uppercased(), tint: .secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Divider()
                HStack(spacing: 18) {
                    DetailChip(label: "Attempts planned", value: "\(decision.plan.attempts.count)")
                    DetailChip(label: "Overall budget", value: decision.plan.overallDeadlineSeconds.msString)
                    DetailChip(label: "Retries per target", value: "\(decision.plan.retry.maxRetriesPerTarget)")
                    DetailChip(label: "Hedging", value: decision.plan.hedging.enabled ? "on" : "off")
                    Spacer()
                }
            }
        }
    }
}

struct DetailChip: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }
}

struct CandidateRow: View {
    var evaluation: CandidateEvaluation
    var maxScore: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(evaluation.rank + 1).")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(evaluation.targetLabel).font(.callout.weight(.medium))
                if let note = evaluation.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !evaluation.components.isEmpty {
                    Text(String(format: "%.3f", evaluation.score))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            if !evaluation.components.isEmpty {
                // Stacked contribution bar: each dimension's share of the score.
                GeometryReader { geo in
                    contributionBar(width: geo.size.width)
                }
                .frame(height: 6)
                .clipShape(Capsule())
            }
        }
        .padding(.vertical, 3)
    }

    /// Stacked contribution bar: each dimension's share of the total score.
    private func contributionBar(width: CGFloat) -> some View {
        HStack(spacing: 1) {
            ForEach(sortedComponents, id: \.0) { entry in
                let name: String = entry.0
                let value: Double = entry.1
                let segment: CGFloat = max(1, width * CGFloat(value / max(0.0001, maxScore)))
                Rectangle()
                    .fill(color(for: name))
                    .frame(width: segment)
                    .help("\(WeightedScoreStrategy.label(for: name)): \(String(format: "%.3f", value))")
            }
            Spacer(minLength: 0)
        }
    }

    private var sortedComponents: [(String, Double)] {
        evaluation.components.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func color(for dimension: String) -> Color {
        switch dimension {
        case "quality": return .blue
        case "latency": return .teal
        case "cost": return .green
        case "health": return .purple
        case "quota": return .orange
        case "priority": return .indigo
        case "localPreference": return .mint
        case "providerPreference": return .pink
        default: return .gray
        }
    }
}

struct RoutingSimulatorView: View {
    @EnvironmentObject private var model: AppModel

    @State private var logicalModel = ""
    @State private var needsVision = false
    @State private var needsTools = false
    @State private var needsJSONSchema = false
    @State private var needsReasoning = false
    @State private var streaming = true
    @State private var contextTokens = 4000.0
    @State private var maxOutput = ""
    @State private var decision: RoutingDecision?
    @State private var error: String?

    var body: some View {
        Page(title: "Routing", subtitle: "Simulate a request and see exactly where it would go, and why") {
            Button {
                Task { await simulate() }
            } label: {
                Label("Simulate", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(logicalModel.isEmpty)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                inputCard
                if let error {
                    Card {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("No route available").font(.headline)
                                Text(error).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                if let decision {
                    RoutingDecisionCard(decision: decision)
                    traceCard(decision)
                }
                if decision == nil && error == nil { policiesOverview }
            }
        }
        .task {
            if logicalModel.isEmpty {
                logicalModel = model.config.logicalModels.first?.name ?? ""
            }
        }
    }

    private var inputCard: some View {
        Card(title: "Request properties", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Logical model").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $logicalModel) {
                            ForEach(model.config.logicalModels) { lm in
                                Text(lm.name).tag(lm.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prompt size: \(Int(contextTokens).formattedTokens) tokens")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $contextTokens, in: 500...500_000)
                            .frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Max output tokens").font(.caption).foregroundStyle(.secondary)
                        TextField("optional", text: $maxOutput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                    Spacer()
                }
                HStack(spacing: 18) {
                    Toggle("Vision", isOn: $needsVision)
                    Toggle("Tools", isOn: $needsTools)
                    Toggle("JSON schema", isOn: $needsJSONSchema)
                    Toggle("Reasoning", isOn: $needsReasoning)
                    Toggle("Streaming", isOn: $streaming)
                    Spacer()
                }
                Text("The simulator runs the real router against live health and quota state. Nothing is sent to any provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func traceCard(_ decision: RoutingDecision) -> some View {
        Card(title: "Decision trace", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                Text(decision.trace)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                Button("Copy trace") { model.copyToPasteboard(decision.trace, label: "Trace") }
                    .buttonStyle(.link)
            }
        }
    }

    private var policiesOverview: some View {
        Card(title: "Policies at a glance",
             subtitle: "Every logical model routes under its own policy", systemImage: "list.bullet") {
            VStack(spacing: 6) {
                ForEach(model.config.logicalModels) { lm in
                    HStack(spacing: 10) {
                        Text(lm.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 110, alignment: .leading)
                        StatusPill(text: lm.policy.strategy.displayName.uppercased(), tint: .accentColor)
                        Text(lm.policy.strategy.summary)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(lm.targets.count) target\(lm.targets.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .rowStyle()
                }
            }
        }
    }

    private func simulate() async {
        var input = DerbyEngine.SimulationInput(logicalModel: logicalModel)
        input.needsVision = needsVision
        input.needsTools = needsTools
        input.needsJSONSchema = needsJSONSchema
        input.needsReasoning = needsReasoning
        input.streaming = streaming
        input.contextTokens = Int(contextTokens)
        input.maxOutputTokens = Int(maxOutput.trimmingCharacters(in: .whitespaces))

        switch await model.engine.simulate(input) {
        case .success(let result):
            decision = result
            error = nil
        case .failure(let e):
            decision = nil
            error = e.message + (e.detail.map { "\n\n\($0)" } ?? "")
        }
    }
}
