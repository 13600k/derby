import SwiftUI
import DerbyCore

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel

    @State private var logicalModel = ""
    @State private var systemPrompt = ""
    @State private var prompt = "Explain the CAP theorem in three sentences."
    @State private var streaming = true
    @State private var output = ""
    @State private var record: RequestRecord?
    @State private var error: DerbyError?
    @State private var isRunning = false
    @State private var startedAt: Date?

    var body: some View {
        Page(title: "Test Console",
             subtitle: "Send a real request through Derby's own routing and execution path") {
            HStack(spacing: 8) {
                Toggle("Stream", isOn: $streaming).toggleStyle(.switch)
                Button {
                    Task { await send() }
                } label: {
                    if isRunning { ProgressView().controlSize(.small).frame(width: 60) }
                    else { Text("Send").frame(width: 60) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || prompt.isEmpty || logicalModel.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                inputCard
                if !output.isEmpty || isRunning { outputCard }
                if let error { errorCard(error) }
                if let record { resultCard(record) }
            }
        }
        .task { if logicalModel.isEmpty { logicalModel = model.config.logicalModels.first?.name ?? "" } }
    }

    private var inputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Logical model").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $logicalModel) {
                            ForEach(model.config.logicalModels) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("System prompt (optional)").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: $systemPrompt).textFieldStyle(.roundedBorder)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prompt").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(.system(size: 13))
                        .frame(height: 92)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                }
                Text("⌘↩ to send. This uses the same router, executor and adapters as the HTTP gateway.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var outputCard: some View {
        Card(title: "Response", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(output.isEmpty ? "…" : output)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 300)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                HStack {
                    if isRunning, let startedAt {
                        Label("streaming · \(Date().timeIntervalSince(startedAt).msString)",
                              systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy") { model.copyToPasteboard(output, label: "Response") }
                        .buttonStyle(.link)
                        .disabled(output.isEmpty)
                }
            }
        }
    }

    private func errorCard(_ error: DerbyError) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(error.kind.displayName).font(.headline)
                        if let status = error.providerStatus {
                            StatusPill(text: "HTTP \(status)", tint: .red)
                        }
                    }
                    Text(error.message).font(.callout).textSelection(.enabled)
                    if let detail = error.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
            }
        }
    }

    private func resultCard(_ record: RequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "How this request was routed", systemImage: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 12) {
                    AdaptiveGrid(minWidth: 140) {
                        DetailChip(label: "Provider", value: record.finalProviderName ?? "—")
                        DetailChip(label: "Model", value: record.finalModelID ?? "—")
                        DetailChip(label: "Total", value: record.totalSeconds.msString)
                        DetailChip(label: "TTFT", value: Format.latency(record.timeToFirstTokenSeconds))
                        DetailChip(label: record.usage.isEstimated ? "Tokens (est.)" : "Tokens",
                                   value: "\(Format.tokens(record.usage.inputTokens, estimated: record.usage.isEstimated)) in / \(record.usage.outputTokens) out")
                        DetailChip(label: "Cost", value: record.costUSD > 0 ? record.costUSD.usdString : "—")
                    }
                    Divider()
                    Text(record.routingExplanation).font(.callout).foregroundStyle(.secondary)
                }
            }
            AttemptsCard(record: record)
        }
    }

    private func send() async {
        isRunning = true
        output = ""
        record = nil
        error = nil
        startedAt = Date()
        defer { isRunning = false }

        let buffer = StreamBuffer()
        // Deltas arrive off the main actor; hop back so the UI updates live.
        let result = await model.engine.runConsole(
            logicalModel: logicalModel,
            prompt: prompt,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            stream: streaming) { event in
                guard case .textDelta(let text) = event, !text.isEmpty else { return }
                buffer.append(text)
                Task { @MainActor in self.output = buffer.text }
            }

        output = buffer.text
        switch result {
        case .success(let finished):
            record = finished
        case .failure(let e):
            error = e
        }
        await model.refreshUsage()
        await model.refreshRequests()
    }
}

/// Thread-safe text accumulation for streamed console output.
final class StreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) { lock.lock(); value += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// Shared attempt timeline, used by the console and the request inspector.
struct AttemptsCard: View {
    var record: RequestRecord

    var body: some View {
        Card(title: "Attempts", subtitle: "\(record.attempts.count) provider invocation\(record.attempts.count == 1 ? "" : "s")",
             systemImage: "list.number") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(record.attempts) { attempt in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(attempt.status))
                            .foregroundStyle(tint(attempt.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(attempt.index + 1). \(attempt.providerName)")
                                    .font(.callout.weight(.medium))
                                Text(attempt.modelID)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                StatusPill(text: attempt.status.displayName, tint: tint(attempt.status))
                                if let kind = attempt.failureKind {
                                    StatusPill(text: kind.rawValue, tint: kind.tint)
                                }
                                if let status = attempt.httpStatus {
                                    Text("HTTP \(status)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                if let ttft = attempt.timeToFirstTokenSeconds {
                                    Text("TTFT \(ttft.msString)").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Total \(attempt.durationSeconds.msString)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if attempt.retryCount > 0 {
                                    Text("\(attempt.retryCount) retr\(attempt.retryCount == 1 ? "y" : "ies")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if attempt.usage.totalTokens > 0 {
                                    Text("\(attempt.usage.inputTokens)/\(attempt.usage.outputTokens) tok")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if attempt.costUSD > 0 {
                                    Text(attempt.costUSD.usdString).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let message = attempt.errorMessage {
                                Text(message).font(.caption)
                                    .foregroundStyle(attempt.status == .failed ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func symbol(_ status: AttemptStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "forward.end.circle"
        case .cancelled: return "minus.circle"
        case .hedgeLost: return "hare"
        }
    }
    private func tint(_ status: AttemptStatus) -> Color {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .skipped: return .orange
        case .cancelled, .hedgeLost: return .secondary
        }
    }
}
