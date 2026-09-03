import SwiftUI
import DerbyCore

struct LogicalModelsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: UUID?
    @State private var newName = ""
    @State private var showNew = false

    private var selected: LogicalModel? {
        model.config.logicalModels.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            list.frame(minWidth: 210, idealWidth: 240, maxWidth: 330)
            if let lm = selected {
                LogicalModelDetailView(modelID: lm.id).id(lm.id)
            } else {
                EmptyStateView(systemImage: "square.stack.3d.up",
                               title: "No logical model selected",
                               message: "A logical model is the name your applications ask for. Each one carries its own routing policy, targets, retry rules and budgets.",
                               actionTitle: "New Logical Model") { showNew = true }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task { if selectedID == nil { selectedID = model.config.logicalModels.first?.id } }
        .sheet(isPresented: $showNew) { newSheet }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logical Models").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New logical model")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()

            List(selection: $selectedID) {
                ForEach(model.config.logicalModels) { lm in
                    LogicalModelRow(lm: lm, usable: usableTargets(lm))
                        .tag(lm.id)
                        .contextMenu {
                            Button("Duplicate") { duplicate(lm) }
                            Button(lm.enabled ? "Disable" : "Enable") { toggle(lm) }
                            Divider()
                            Button("Delete", role: .destructive) { delete(lm) }
                        }
                }
                .onMove { indices, destination in
                    Task {
                        await model.mutate { $0.logicalModels.move(fromOffsets: indices, toOffset: destination) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func usableTargets(_ lm: LogicalModel) -> Int {
        guard let resolved = model.snapshot.logicalModel(named: lm.name) else { return 0 }
        return resolved.targets.filter { $0.unavailableReason == nil }.count
    }

    private var newSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New logical model").font(.title3.weight(.semibold))
            Text("Clients will ask for this name in the `model` field.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("e.g. reasoning", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if !newName.isEmpty && !model.config.isLogicalModelNameAvailable(newName) {
                Label("That name is already in use.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { showNew = false; newName = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.config.isLogicalModelNameAvailable(newName))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.config.isLogicalModelNameAvailable(name) else { return }
        let lm = LogicalModel(name: name, summary: "")
        Task {
            await model.mutate("Created \(name)") { $0.logicalModels.append(lm) }
            selectedID = lm.id
        }
        showNew = false
        newName = ""
    }

    private func duplicate(_ lm: LogicalModel) {
        var copy = lm
        copy.id = UUID()
        var candidate = "\(lm.name)-copy"
        var n = 2
        while !model.config.isLogicalModelNameAvailable(candidate) {
            candidate = "\(lm.name)-copy-\(n)"
            n += 1
        }
        copy.name = candidate
        copy.targets = lm.targets.map { target in
            var t = target
            t.id = UUID()
            return t
        }
        copy.createdAt = Date()
        Task {
            await model.mutate("Duplicated as \(candidate)") { $0.logicalModels.append(copy) }
            selectedID = copy.id
        }
    }

    private func toggle(_ lm: LogicalModel) {
        Task {
            await model.mutate { config in
                guard let i = config.logicalModels.firstIndex(where: { $0.id == lm.id }) else { return }
                config.logicalModels[i].enabled.toggle()
            }
        }
    }

    private func delete(_ lm: LogicalModel) {
        Task {
            await model.mutate("Deleted \(lm.name)") { $0.logicalModels.removeAll { $0.id == lm.id } }
            if selectedID == lm.id { selectedID = model.config.logicalModels.first?.id }
        }
    }
}

struct LogicalModelRow: View {
    var lm: LogicalModel
    var usable: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lm.enabled ? "square.stack.3d.up.fill" : "square.stack.3d.up.slash")
                .foregroundStyle(lm.enabled ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(lm.name)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(lm.enabled ? .primary : .secondary)
                Text(lm.policy.strategy.displayName)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(usable)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(usable == 0 ? .orange : .secondary)
        }
        .padding(.vertical, 2)
    }
}
