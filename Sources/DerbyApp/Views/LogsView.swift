import SwiftUI
import DerbyCore

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    var body: some View {
        Page(title: "Logs", subtitle: "Structured, redacted diagnostics") {
            HStack(spacing: 8) {
                Picker("", selection: $model.logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: model.logLevel) { _, _ in Task { await model.refreshLogs() } }

                Button { Task { await model.refreshLogs() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button {
                    model.copyToPasteboard(model.logs.map(\.formatted).joined(separator: "\n"), label: "Logs")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    Task {
                        let diagnostics = await model.engine.exportDiagnostics()
                        save(diagnostics)
                    }
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                if filtered.isEmpty {
                    Card {
                        Text("No log entries at this level.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Format.time(entry.at))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 62, alignment: .leading)
                                    StatusPill(text: entry.level.rawValue.uppercased(), tint: tint(entry.level))
                                        .frame(width: 54, alignment: .leading)
                                    Text(entry.category)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 68, alignment: .leading)
                                    Text(entry.message)
                                        .font(.system(size: 11))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let requestID = entry.requestID {
                                        Text(String(requestID.suffix(8)))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 3)
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }
            }
        }
        .task { await model.refreshLogs() }
    }

    private var filtered: [LogEntry] {
        guard !search.isEmpty else { return model.logs }
        return model.logs.filter {
            $0.message.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
        }
    }

    private func tint(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .derbyAccent
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "derby-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            model.show(.success, "Diagnostics exported")
        }
    }
}
