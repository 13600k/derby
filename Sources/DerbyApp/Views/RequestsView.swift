import SwiftUI
import DerbyCore

struct RequestsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: String?

    private var selected: RequestRecord? {
        model.requests.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            listPane.frame(minWidth: 340, idealWidth: 420, maxWidth: 560)
            if let record = selected {
                RequestInspector(record: record).id(record.id)
            } else {
                EmptyStateView(systemImage: "list.bullet.rectangle",
                               title: "No request selected",
                               message: "Every request Derby handles is recorded with its candidates, attempts, timings and the reason a provider was chosen.")
                    .frame(maxWidth: .infinity)
                    .glassPane(stain: 0.04)
            }
        }
        .task { await model.refreshRequests() }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Text("Requests").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button { Task { await model.refreshRequests() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                TextField("Search id, model, client or error", text: $model.requestFilter.search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refreshRequests() } }
                HStack(spacing: 10) {
                    Toggle("Failures", isOn: $model.requestFilter.onlyFailures)
                        .toggleStyle(.checkbox)
                        .onChange(of: model.requestFilter.onlyFailures) { _, _ in
                            Task { await model.refreshRequests() }
                        }
                    Toggle("Failovers", isOn: $model.requestFilter.onlyFailovers)
                        .toggleStyle(.checkbox)
                        .onChange(of: model.requestFilter.onlyFailovers) { _, _ in
                            Task { await model.refreshRequests() }
                        }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.requestFilter.logicalModel ?? "" },
                        set: { newValue in
                            model.requestFilter.logicalModel = newValue.isEmpty ? nil : newValue
                            Task { await model.refreshRequests() }
                        })) {
                        Text("All models").tag("")
                        ForEach(model.config.logicalModels) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()

            if model.requests.isEmpty {
                EmptyStateView(systemImage: "tray",
                               title: "No requests yet",
                               message: "Point an OpenAI-compatible client at Derby, or use the Test Console.")
            } else {
                List(model.requests, selection: $selectedID) { record in
                    RequestRow(record: record).tag(record.id)
                }
                .listStyle(.inset)
                .clearScrollBackground()
            }
        }
        .glassSurface(.chrome, in: Rectangle())
    }
}

struct RequestRow: View {
    var record: RequestRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(record.succeeded ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.logicalModel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Text(record.finalModelID ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if record.failoverCount > 0 {
                        StatusPill(text: "FAILOVER ×\(record.failoverCount)", tint: .orange)
                    }
                    if record.streaming {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(Format.relative(record.createdAt))
                    Text(record.totalSeconds.msString)
                    if record.usage.totalTokens > 0 { Text("\(Format.count(record.usage.totalTokens)) tok") }
                    if record.costUSD > 0 { Text(record.costUSD.usdString) }
                    if let kind = record.failureKind {
                        Text(kind.rawValue).foregroundStyle(kind.tint)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct RequestInspector: View {
    @EnvironmentObject private var model: AppModel
    var record: RequestRecord

    var body: some View {
        Page(title: record.logicalModel,
             subtitle: "\(record.id) · \(Format.dateTime(record.createdAt))") {
            Button {
                model.copyToPasteboard(record.inspectorSummary, label: "Request summary")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard
                AttemptsCard(record: record)
                routingCard
                if !record.evaluations.isEmpty || !record.exclusions.isEmpty { candidatesCard }
                if record.promptExcerpt != nil || record.responseExcerpt != nil { contentCard }
            }
        }
        .glassPane(stain: 0.04)
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.title2)
                        .foregroundStyle(record.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.succeeded ? "Completed" : (record.failureKind?.displayName ?? "Failed"))
                            .font(.headline)
                        if let message = record.errorMessage {
                            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    StatusPill(text: "HTTP \(record.httpStatus)",
                               tint: record.succeeded ? .green : .red)
                }
                Divider()
                AdaptiveGrid(minWidth: 130) {
                    DetailChip(label: "Provider", value: record.finalProviderName ?? "—")
                    DetailChip(label: "Physical model", value: record.finalModelID ?? "—")
                    DetailChip(label: "Client", value: record.clientName)
                    DetailChip(label: "API", value: record.dialect)
                    DetailChip(label: "Total", value: record.totalSeconds.msString)
                    DetailChip(label: "TTFT", value: Format.latency(record.timeToFirstTokenSeconds))
                    DetailChip(label: record.usage.isEstimated ? "Input tokens (est.)" : "Input tokens",
                               value: Format.tokens(record.usage.inputTokens, estimated: record.usage.isEstimated))
                    DetailChip(label: record.usage.isEstimated ? "Output tokens (est.)" : "Output tokens",
                               value: Format.tokens(record.usage.outputTokens, estimated: record.usage.isEstimated))
                    if record.usage.cachedInputTokens > 0 {
                        DetailChip(label: "Cached", value: Format.count(record.usage.cachedInputTokens))
                    }
                    if record.usage.reasoningTokens > 0 {
                        DetailChip(label: "Reasoning", value: Format.count(record.usage.reasoningTokens))
                    }
                    DetailChip(label: "Cost", value: record.costUSD > 0 ? record.costUSD.usdString : "—")
                    DetailChip(label: "Retries / failovers", value: "\(record.retryCount) / \(record.failoverCount)")
                }
            }
        }
    }

    private var routingCard: some View {
        Card(title: "Why this provider", systemImage: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusPill(text: record.routingStrategy.uppercased(), tint: .derbyAccent)
                    Spacer()
                }
                Text(record.routingExplanation)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A shortened conversation is the one thing here the user did
                // not ask for on this request, so it gets its own callout
                // rather than a line buried in the narrative.
                if let c = record.compaction {
                    Divider()
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Conversation shortened to fit")
                                .font(.callout.weight(.semibold))
                            Text(c.summary)
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let f = c.summaryFailure {
                                Text("Summary unavailable: \(f)")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The conversation moved between models, or had to change to
                // reach this one: what the answering model did and did not get.
                if let h = record.handoff, h.isNotable {
                    Divider()
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(handoffTitle(h)).font(.callout.weight(.semibold))
                            Text(h.summary)
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(h.reasoningWithheld + h.signedReasoningWithheld > 0 ? .orange : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func handoffTitle(_ h: HandoffRecord) -> String {
        guard let previous = h.previousModel, previous != h.targetModel else {
            return "Conversation carried to \(h.targetModel)"
        }
        return "Conversation handed from \(previous) to \(h.targetModel) (\(h.affinity.displayName))"
    }

    private var candidatesCard: some View {
        Card(title: "Candidates considered", systemImage: "list.number") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(record.evaluations, id: \.rank) { evaluation in
                    CandidateRow(evaluation: evaluation, maxScore: record.evaluations.first?.score ?? 1)
                }
                if !record.exclusions.isEmpty {
                    Divider()
                    ForEach(Array(record.exclusions.enumerated()), id: \.offset) { _, exclusion in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(exclusion.targetLabel).font(.callout)
                                Text(exclusion.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: exclusion.stage.displayName.uppercased(), tint: .secondary)
                        }
                    }
                }
            }
        }
    }

    private var contentCard: some View {
        Card(title: "Content", subtitle: "Stored because prompt logging is enabled",
             systemImage: "text.quote") {
            VStack(alignment: .leading, spacing: 10) {
                if let prompt = record.promptExcerpt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt").font(.caption).foregroundStyle(.secondary)
                        Text(prompt).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .glassSurface(.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                if let response = record.responseExcerpt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Response").font(.caption).foregroundStyle(.secondary)
                        Text(response).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .glassSurface(.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
    }
}
