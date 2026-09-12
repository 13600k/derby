import SwiftUI
import DerbyCore

struct LogicalModelDetailView: View {
    @EnvironmentObject private var model: AppModel
    let modelID: UUID

    @State private var draft: LogicalModel?
    @State private var showAddTarget = false
    @State private var testResult: RoutingDecision?
    @State private var testError: String?

    private var current: LogicalModel? { model.config.logicalModels.first { $0.id == modelID } }

    var body: some View {
        Group {
            if let lm = draft {
                content(lm)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { draft = current }
        .glassPane(stain: 0.04)
        .sheet(isPresented: $showAddTarget) {
            AddTargetSheet(existing: draft?.targets ?? []) { refs in
                draft?.targets.append(contentsOf: refs)
                save()
            }
            .environmentObject(model)
            .derbyGlassSheet()
        }
    }

    private func content(_ lm: LogicalModel) -> some View {
        Page(title: lm.name, subtitle: lm.summary.isEmpty ? "Logical model" : lm.summary) {
            HStack(spacing: 10) {
                Toggle("Enabled", isOn: binding(\.enabled))
                    .toggleStyle(.switch)
                    .onChange(of: lm.enabled) { _, _ in save() }
                Button {
                    runTest()
                } label: {
                    Label("Test Routing", systemImage: "play.circle")
                }
                .derbyProminentButton()
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if let testResult { RoutingDecisionCard(decision: testResult) { self.testResult = nil } }
                if let testError {
                    Card {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            Text(testError).font(.callout)
                            Spacer()
                            Button { self.testError = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                identityCard(lm)
                contractCard(lm)
                strategyCard(lm)
                targetsCard(lm)
                if lm.policy.strategy.usesScoreWeights { weightsCard(lm) }
                compactionCard(lm)
                handoffCard(lm)
                reliabilityCard(lm)
                dispositionCard(lm)
                defaultsCard(lm)
                budgetCard(lm)
            }
        }
    }


    /// What to do when the conversation is larger than the model that has to
    /// answer it.
    ///
    /// Off by default, and deliberately so: shortening a conversation changes
    /// the answer, and a user who has not asked for that should get a clear
    /// error instead of a quietly worse response. Turning it on trades
    /// exactness for reach, and every affected response says it happened.
    @ViewBuilder
    private func compactionCard(_ lm: LogicalModel) -> some View {
        let policy = lm.compaction ?? .disabled
        let summary = model.snapshot.logicalModel(named: lm.name)
            .map { LogicalModelCapabilitySummary.summarize($0) } ?? .empty

        Card(title: "When the conversation is too long",
             subtitle: "Skip the smaller target, or shorten the conversation to fit it",
             systemImage: "arrow.down.right.and.arrow.up.left") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Shorten the conversation instead of skipping the target",
                       isOn: compactionBinding(\.enabled))
                    .onChange(of: policy.enabled) { _, _ in save() }

                if let floor = summary.guaranteedContextWindow, let ceiling = summary.maxContextWindow,
                   floor < ceiling {
                    Text("Targets in this group range from \(floor.formattedTokens) to \(ceiling.formattedTokens) of context. Without this, a conversation over \(floor.formattedTokens) can only use the larger ones.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("With this off, a request that does not fit a target is routed past it, and fails when no target is large enough.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if policy.enabled {
                    Divider()

                    Picker("Method", selection: compactionBinding(\.strategy)) {
                        ForEach(CompactionPolicy.Strategy.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: policy.strategy) { _, _ in save() }

                    Text(policy.strategy.summary)
                        .font(.caption).foregroundStyle(.secondary)

                    if policy.strategy == .summarize {
                        LabeledContent("Written by") {
                            Picker("", selection: compactorBinding()) {
                                Text("Choose a model…").tag(CompactorSelection?.none)
                                ForEach(model.config.providers.filter(\.enabled)) { account in
                                    ForEach(account.models.filter(\.enabled)) { pm in
                                        Text("\(account.name) · \(pm.label)")
                                            .tag(Optional(CompactorSelection(providerID: account.id, modelUUID: pm.id)))
                                    }
                                }
                            }
                            .labelsHidden()
                            .onChange(of: policy.compactor) { _, _ in save() }
                        }
                        if policy.compactor == nil {
                            Label("Without a model to write the summary, older turns are dropped instead.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("A cheap, large-context model is the right choice here. It reads what is being removed, so it should be one you are comfortable sending the whole conversation to.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    AdaptiveGrid(minWidth: 190) {
                        NumberField(label: "Keep this many recent messages",
                                    value: compactionBinding(\.keepRecentMessages),
                                    range: 1...100, onCommit: save)
                        NumberField(label: "Fill at most this much of the window",
                                    value: compactionBinding(\.targetUtilization),
                                    range: 0.1...1.0, onCommit: save)
                        NumberField(label: "Summarizing timeout (s)",
                                    value: compactionBinding(\.timeoutSeconds),
                                    range: 5...600, onCommit: save)
                    }

                    Label("Every response shortened this way reports it in x_derby.compaction, on the x-derby-compacted header, and in request history.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// What the next model receives when the one answering changes.
    ///
    /// Structure is always adapted — that only prevents rejections, so there is
    /// nothing to choose. Reasoning is the choice, and it only ever goes to the
    /// same lineage.
    private func handoffCard(_ lm: LogicalModel) -> some View {
        Card(title: "When the conversation changes model",
             subtitle: "What the next model receives from the one before it",
             systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Carry reasoning to a model of the same lineage", isOn: Binding(
                    get: { (draft?.handoff ?? current?.handoff ?? .default).replayReasoning },
                    set: { on in
                        var policy = draft?.handoff ?? .default
                        policy.replayReasoning = on
                        draft?.handoff = policy
                        save()
                    }))
                Text("When a tool loop continues on the same weights — the same model at another quantization, or on another server — or on the same provider's API, it picks up the previous step's reasoning where it stopped. Reasoning is never sent to a different model family, which would read it as something the assistant said.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Structure is always adapted to the model answering — tool call ids, system messages, turn order, tool results — and every response that changed model reports what it carried in x_derby.handoff and request history.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cards

    private func identityCard(_ lm: LogicalModel) -> some View {
        Card(title: "Identity", systemImage: "tag") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Name") {
                    TextField("", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { commitRename() }
                }
                if !model.config.isLogicalModelNameAvailable(lm.name, excluding: lm.id) {
                    Label("Another logical model already uses this name.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Description") {
                    TextField("What this group is for", text: binding(\.summary))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                }
            }
        }
    }

    /// What this group offers clients, and how far the user has narrowed it.
    ///
    /// Model capabilities themselves are facts from the provider and are not
    /// editable in Providers. What *is* a decision is the contract presented
    /// here: a group whose targets all support vision can still be declared
    /// text-only, and a 200k group can be capped lower.
    @ViewBuilder
    private func contractCard(_ lm: LogicalModel) -> some View {
        let summary = model.snapshot.logicalModel(named: lm.name)
            .map { LogicalModelCapabilitySummary.summarize($0) } ?? .empty
        let raw = summary.unconstrained ?? summary.available
        let guaranteedRaw = rawGuaranteed(lm)

        Card(title: "What this model offers",
             subtitle: "Derived from the targets below — narrow it here, never in Providers",
             systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 14) {
                if summary.targetCount == 0 {
                    Text("No target can serve this group yet. Add one below.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Supported by every target")
                            .font(.caption).foregroundStyle(.secondary)
                        FlowLayout(spacing: 5) {
                            ForEach(CapabilityFlags.allNames, id: \.1) { flag, name in
                                if guaranteedRaw.contains(flag) {
                                    Toggle(name, isOn: Binding(
                                        get: { summary.available.contains(flag) },
                                        set: { on in setCapability(flag, enabled: on, offeredBy: guaranteedRaw) }))
                                    .toggleStyle(.button)
                                    .controlSize(.small)
                                    .font(.caption2)
                                }
                            }
                        }
                        Text("These are the abilities all of this group's targets share, so a request using them keeps full failover. Uncheck one to stop offering it.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let partialRaw = raw.subtracting(guaranteedRaw)
                    if !partialRaw.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Supported by only some targets")
                                .font(.caption).foregroundStyle(.secondary)
                            FlowLayout(spacing: 5) {
                                ForEach(CapabilityFlags.allNames, id: \.1) { flag, name in
                                    if partialRaw.contains(flag) {
                                        Toggle(name, isOn: Binding(
                                            get: { summary.available.contains(flag) },
                                            set: { on in setCapability(flag, enabled: on, offeredBy: raw) }))
                                        .toggleStyle(.button)
                                        .controlSize(.small)
                                        .font(.caption2)
                                        .tint(.orange)
                                    }
                                }
                            }
                            Text("Requests using these still work — Derby routes them to the targets that qualify — but with fewer alternatives to fail over to.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !summary.incompatible.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.incompatible, id: \.targetLabel) { item in
                                Label("\(item.targetLabel) — \(item.reason)",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Divider()

                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CONTEXT").font(.system(size: 9, weight: .semibold))
                                .tracking(0.4).foregroundStyle(.secondary)
                            Text(summary.maxContextWindow.map { $0.formattedTokens } ?? "not reported")
                                .font(.callout.weight(.medium))
                            if let floor = summary.guaranteedContextWindow,
                               floor != summary.maxContextWindow {
                                Text("\(floor.formattedTokens) with every target")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        OptionalNumberField(label: "Cap prompt at (tokens)",
                                            value: constraintBinding(\.maxContextTokens),
                                            onCommit: save)
                            .frame(width: 170)
                        OptionalNumberField(label: "Cap answer at (tokens)",
                                            value: constraintBinding(\.maxOutputTokens),
                                            onCommit: save)
                            .frame(width: 170)
                        Spacer()
                    }

                    if summary.isNarrowed || lm.constraints?.maxContextTokens != nil {
                        HStack {
                            Label("This group deliberately offers less than its targets support.",
                                  systemImage: "arrow.down.right.circle")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Reset to targets") {
                                draft?.constraints = nil
                                save()
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Text("Clients read this from /v1/models, and Derby enforces it: a request needing something you unchecked is refused here rather than routed anyway.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Capabilities the targets actually share, before any narrowing.
    private func rawGuaranteed(_ lm: LogicalModel) -> CapabilityFlags {
        guard let resolved = model.snapshot.logicalModel(named: lm.name) else { return [] }
        var stripped = resolved
        stripped.definition.constraints = nil
        return LogicalModelCapabilitySummary.summarize(stripped).guaranteed
    }

    /// Ticking a box removes it from the mask; unticking adds the mask if absent.
    private func setCapability(_ flag: CapabilityFlags, enabled: Bool, offeredBy supported: CapabilityFlags) {
        var constraints = draft?.constraints ?? LogicalModelConstraints()
        var allowed = constraints.allowedCapabilities ?? supported
        if enabled { allowed.insert(flag) } else { allowed.remove(flag) }
        // A mask that allows everything is no mask at all.
        constraints.allowedCapabilities = allowed.isSuperset(of: supported) ? nil : allowed
        draft?.constraints = constraints.isEmpty ? nil : constraints
        save()
    }

    private func constraintBinding(_ keyPath: WritableKeyPath<LogicalModelConstraints, Int?>) -> Binding<Int?> {
        Binding(
            get: { draft?.constraints?[keyPath: keyPath] },
            set: { newValue in
                var constraints = draft?.constraints ?? LogicalModelConstraints()
                constraints[keyPath: keyPath] = newValue
                draft?.constraints = constraints.isEmpty ? nil : constraints
            })
    }

    private func strategyCard(_ lm: LogicalModel) -> some View {
        Card(title: "Routing strategy",
             subtitle: "This policy belongs to \(lm.name) alone", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Strategy", selection: binding(\.policy.strategy)) {
                    ForEach(RoutingStrategyKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                .onChange(of: lm.policy.strategy) { _, _ in save() }

                Text(lm.policy.strategy.summary)
                    .font(.callout).foregroundStyle(.secondary)

                if lm.policy.strategy == .lowestLatency || lm.policy.strategy.usesScoreWeights {
                    Picker("Latency metric", selection: binding(\.policy.latencyMetric)) {
                        ForEach(LatencyMetric.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                    .onChange(of: lm.policy.latencyMetric) { _, _ in save() }
                }

                HStack(spacing: 20) {
                    Toggle("Skip targets with an open circuit", isOn: binding(\.policy.respectCircuitBreakers))
                        .onChange(of: lm.policy.respectCircuitBreakers) { _, _ in save() }
                    Toggle("Skip rate-limited targets", isOn: binding(\.policy.respectQuotas))
                        .onChange(of: lm.policy.respectQuotas) { _, _ in save() }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Prefer a copy of the model that is already loaded", isOn: Binding(
                        get: { (draft ?? lm).policy.effectivePreferWarmModels },
                        set: { on in
                            draft?.policy.preferWarmModels = on
                            save()
                        }))
                    Text(lm.policy.strategy.respectsConfiguredOrder && lm.policy.preferWarmModels == nil
                         ? "Off by default for this strategy, which follows the order you set."
                         : "When two targets serve the same model, the one a local server already holds in memory goes first, so the answer does not wait on a cold load.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    NumberField(label: "Max candidates per request",
                                value: intBinding(\.policy.maxCandidates), range: 1...16, onCommit: save)
                        .frame(width: 190)
                    Toggle("Deterministic tie-breaking", isOn: binding(\.policy.deterministic))
                        .onChange(of: lm.policy.deterministic) { _, _ in save() }
                    Spacer()
                }
            }
        }
    }

    private func targetsCard(_ lm: LogicalModel) -> some View {
        Card(title: "Targets",
             subtitle: orderMatters(lm) ? "Drag to reorder — order is priority" : "Ranked by the strategy at request time",
             systemImage: "list.number") {
            VStack(alignment: .leading, spacing: 8) {
                if lm.targets.isEmpty {
                    Text("No targets yet. Add provider models this logical model may use.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(Array(lm.targets.enumerated()), id: \.element.id) { index, ref in
                            TargetRow(index: index, ref: ref, lm: lm,
                                      resolved: resolve(ref),
                                      health: healthFor(ref),
                                      showWeight: lm.policy.strategy.usesWeights,
                                      onUpdate: { updated in
                                          if let i = draft?.targets.firstIndex(where: { $0.id == ref.id }) {
                                              draft?.targets[i] = updated
                                              save()
                                          }
                                      },
                                      onRemove: {
                                          draft?.targets.removeAll { $0.id == ref.id }
                                          save()
                                      })
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        }
                        .onMove { indices, destination in
                            draft?.targets.move(fromOffsets: indices, toOffset: destination)
                            save()
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(lm.targets.count) * 62 + 8)
                }
                Button {
                    showAddTarget = true
                } label: {
                    Label("Add Target", systemImage: "plus")
                }
            }
        }
    }

    private func orderMatters(_ lm: LogicalModel) -> Bool {
        switch lm.policy.strategy {
        case .priority, .failoverChain, .roundRobin: return true
        default: return false
        }
    }

    private func weightsCard(_ lm: LogicalModel) -> some View {
        let weights = lm.policy.scoreWeights
        let normalized = weights.normalized
        return Card(title: "Score weights",
                    subtitle: "Relative importance of each dimension — Derby normalizes them for you",
                    systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(weights.dimensions, id: \.name) { dimension in
                    let value = weights[keyPath: dimension.key]
                    let share = normalized[keyPath: dimension.key]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(dimension.name).font(.callout)
                            Spacer()
                            Text(Format.percent(share))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Slider(value: Binding(
                                get: { value },
                                set: { draft?.policy.scoreWeights[keyPath: dimension.key] = $0 }
                            ), in: 0...1, step: 0.05) { editing in
                                if !editing { save() }
                            }
                            WeightBar(value: share).frame(width: 70)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Balanced") { applyWeights(.balanced) }
                    Button("Quality first") { applyWeights(.qualityFirst) }
                    Button("Cheapest") { applyWeights(.cheap) }
                    Button("Fastest") { applyWeights(.fast) }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func reliabilityCard(_ lm: LogicalModel) -> some View {
        Card(title: "Retries, failover & timeouts",
             subtitle: "A retry re-tries the same target; a failover moves to the next one",
             systemImage: "arrow.clockwise.circle") {
            VStack(alignment: .leading, spacing: 14) {
                AdaptiveGrid(minWidth: 190) {
                    NumberField(label: "Retries per target", value: intBinding(\.retry.maxRetriesPerTarget),
                                range: 0...5, onCommit: save)
                    NumberField(label: "Initial backoff (s)", value: binding(\.retry.initialBackoffSeconds),
                                range: 0...30, onCommit: save)
                    NumberField(label: "Backoff multiplier", value: binding(\.retry.backoffMultiplier),
                                range: 1...10, onCommit: save)
                    NumberField(label: "Max attempts (total)", value: intBinding(\.failover.maxAttempts),
                                range: 1...10, onCommit: save)
                    NumberField(label: "Overall timeout (s)", value: binding(\.timeouts.overallSeconds),
                                range: 1...1800, onCommit: save)
                    NumberField(label: "Per-attempt timeout (s)", value: binding(\.timeouts.perAttemptSeconds),
                                range: 1...1800, onCommit: save)
                    NumberField(label: "First-token timeout (s)", value: binding(\.timeouts.firstTokenSeconds),
                                range: 1...600, onCommit: save)
                }
                HStack(spacing: 20) {
                    Toggle("Enable failover", isOn: binding(\.failover.enabled))
                        .onChange(of: lm.failover.enabled) { _, _ in save() }
                    Toggle("Honour Retry-After", isOn: binding(\.retry.respectRetryAfter))
                        .onChange(of: lm.retry.respectRetryAfter) { _, _ in save() }
                    Toggle("Jitter backoff", isOn: binding(\.retry.jitter))
                        .onChange(of: lm.retry.jitter) { _, _ in save() }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Hedge slow requests to a second target", isOn: binding(\.hedging.enabled))
                        .onChange(of: lm.hedging.enabled) { _, _ in save() }
                    if lm.hedging.enabled {
                        HStack(spacing: 16) {
                            NumberField(label: "Start hedge after (s)", value: binding(\.hedging.delaySeconds),
                                        range: 0.1...30, onCommit: save)
                                .frame(width: 170)
                            NumberField(label: "Max parallel attempts", value: intBinding(\.hedging.maxParallel),
                                        range: 2...4, onCommit: save)
                                .frame(width: 170)
                            Spacer()
                        }
                        Label("Hedging can double the cost of a request. It is off by default.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if lm.policy.strategy == .failoverChain && lm.hedging.enabled {
                        Label("A strict failover chain never runs targets in parallel, so hedging is ignored here.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func dispositionCard(_ lm: LogicalModel) -> some View {
        Card(title: "Failure handling",
             subtitle: "What Derby does for each kind of provider failure",
             systemImage: "exclamationmark.triangle") {
            VStack(spacing: 4) {
                ForEach(FailureKind.allCases, id: \.self) { kind in
                    HStack(spacing: 10) {
                        Text(kind.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 170, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { lm.failover.dispositions[kind] ?? kind.defaultDisposition },
                            set: { newValue in
                                if newValue == kind.defaultDisposition {
                                    draft?.failover.dispositions.removeValue(forKey: kind)
                                } else {
                                    draft?.failover.dispositions[kind] = newValue
                                }
                                save()
                            })) {
                            ForEach(FailureDisposition.allCases, id: \.self) { d in
                                Text(d.displayName).tag(d)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                        if lm.failover.dispositions[kind] != nil {
                            Button("Reset") {
                                draft?.failover.dispositions.removeValue(forKey: kind)
                                save()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func defaultsCard(_ lm: LogicalModel) -> some View {
        Card(title: "Request defaults",
             subtitle: "Applied when the client does not specify them", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 12) {
                AdaptiveGrid(minWidth: 180) {
                    OptionalDoubleField(label: "Temperature",
                                        value: optionalDoubleBinding(\.defaults.temperature),
                                        placeholder: "provider default", onCommit: save)
                    OptionalDoubleField(label: "Top P", value: optionalDoubleBinding(\.defaults.topP),
                                        placeholder: "provider default", onCommit: save)
                    OptionalNumberField(label: "Max output tokens",
                                        value: optionalIntBinding(\.defaults.maxOutputTokens), onCommit: save)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("System prompt").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { draft?.defaults.systemPrompt ?? "" },
                        set: { draft?.defaults.systemPrompt = $0.isEmpty ? nil : $0 }))
                        .font(.callout)
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .glassSurface(.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: lm.defaults.systemPrompt) { _, _ in save() }
                    Picker("Applied by", selection: binding(\.defaults.systemPromptMode)) {
                        ForEach(RequestDefaults.SystemPromptMode.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                    .onChange(of: lm.defaults.systemPromptMode) { _, _ in save() }
                }
                Picker("Reasoning effort", selection: Binding(
                    get: { draft?.defaults.reasoningEffort ?? .medium },
                    set: { draft?.defaults.reasoningEffort = $0; save() })) {
                    Text("Unset").tag(ReasoningEffort.medium)
                    ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)
            }
        }
    }

    private func budgetCard(_ lm: LogicalModel) -> some View {
        Card(title: "Budget", subtitle: "Unknown pricing never blocks routing", systemImage: "dollarsign.circle") {
            VStack(alignment: .leading, spacing: 10) {
                AdaptiveGrid(minWidth: 190) {
                    OptionalDoubleField(label: "Max cost per request (USD)",
                                        value: optionalDoubleBinding(\.budget.maxCostPerRequestUSD),
                                        onCommit: save)
                    OptionalDoubleField(label: "Daily cap (USD)",
                                        value: optionalDoubleBinding(\.budget.dailyCostCapUSD), onCommit: save)
                    OptionalDoubleField(label: "Monthly cap (USD)",
                                        value: optionalDoubleBinding(\.budget.monthlyCostCapUSD), onCommit: save)
                }
                Toggle("Fall back to free and local targets when a cap is reached",
                       isOn: binding(\.budget.degradeToFreeTargets))
                    .onChange(of: lm.budget.degradeToFreeTargets) { _, _ in save() }
            }
        }
    }

    // MARK: - Helpers

    private func resolve(_ ref: TargetRef) -> (ProviderAccount, PhysicalModel)? {
        model.config.resolve(ref)
    }

    private func healthFor(_ ref: TargetRef) -> TargetHealth? {
        guard let (account, physical) = resolve(ref) else { return nil }
        return model.health(providerID: account.id, modelID: physical.modelID)
    }

    private func applyWeights(_ weights: ScoreWeights) {
        draft?.policy.scoreWeights = weights
        save()
    }

    /// `compaction` is optional on disk so older configs still decode. The UI
    /// always edits a concrete value, materializing the default on first touch.
    private func compactionBinding<T>(_ keyPath: WritableKeyPath<CompactionPolicy, T>) -> Binding<T> {
        Binding(get: { (draft?.compaction ?? current?.compaction ?? .disabled)[keyPath: keyPath] },
                set: { newValue in
                    var policy = draft?.compaction ?? .disabled
                    policy[keyPath: keyPath] = newValue
                    draft?.compaction = policy
                })
    }
    private func compactorBinding() -> Binding<CompactorSelection?> {
        Binding(get: { draft?.compaction?.compactor ?? current?.compaction?.compactor },
                set: { newValue in
                    var policy = draft?.compaction ?? .disabled
                    policy.compactor = newValue
                    draft?.compaction = policy
                })
    }

    private func binding<T>(_ keyPath: WritableKeyPath<LogicalModel, T>) -> Binding<T> {
        Binding(get: { draft?[keyPath: keyPath] ?? current![keyPath: keyPath] },
                set: { draft?[keyPath: keyPath] = $0 })
    }
    private func intBinding(_ keyPath: WritableKeyPath<LogicalModel, Int>) -> Binding<Int> {
        Binding(get: { draft?[keyPath: keyPath] ?? 0 }, set: { draft?[keyPath: keyPath] = $0 })
    }
    private func optionalIntBinding(_ keyPath: WritableKeyPath<LogicalModel, Int?>) -> Binding<Int?> {
        Binding(get: { draft?[keyPath: keyPath] ?? nil }, set: { draft?[keyPath: keyPath] = $0 })
    }
    private func optionalDoubleBinding(_ keyPath: WritableKeyPath<LogicalModel, Double?>) -> Binding<Double?> {
        Binding(get: { draft?[keyPath: keyPath] ?? nil }, set: { draft?[keyPath: keyPath] = $0 })
    }

    private func commitRename() {
        guard let draft, model.config.isLogicalModelNameAvailable(draft.name, excluding: draft.id) else { return }
        save()
    }

    private func save() {
        guard var draft else { return }
        draft.updatedAt = Date()
        self.draft = draft
        let snapshot = draft
        Task {
            await model.mutate { config in
                guard let i = config.logicalModels.firstIndex(where: { $0.id == snapshot.id }) else { return }
                config.logicalModels[i] = snapshot
            }
        }
    }

    private func runTest() {
        guard let lm = draft else { return }
        Task {
            // Probe with what this group actually offers, so "Test Routing"
            // exercises a request the group is expected to serve.
            let offered = model.snapshot.logicalModel(named: lm.name)
                .map { LogicalModelCapabilitySummary.summarize($0).guaranteed } ?? []
            var input = DerbyEngine.SimulationInput(logicalModel: lm.name)
            input.needsTools = offered.contains(.tools)
            input.needsVision = offered.contains(.vision)
            switch await model.engine.simulate(input) {
            case .success(let decision):
                testResult = decision
                testError = nil
            case .failure(let error):
                testResult = nil
                testError = error.message
            }
        }
    }
}

/// A draggable target row with inline routing knobs.
struct TargetRow: View {
    var index: Int
    var ref: TargetRef
    var lm: LogicalModel
    var resolved: (ProviderAccount, PhysicalModel)?
    var health: TargetHealth?
    var showWeight: Bool
    var onUpdate: (TargetRef) -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Toggle("", isOn: Binding(get: { ref.enabled }, set: { on in
                var updated = ref; updated.enabled = on; onUpdate(updated)
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                if let (account, physical) = resolved {
                    HStack(spacing: 6) {
                        Text(physical.label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if let health, health.circuit == .open {
                            StatusPill(text: "CIRCUIT OPEN", tint: .red, systemImage: "bolt.slash")
                        }
                    }
                    Text(detailLine(account, physical))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Missing provider or model")
                        .font(.callout).foregroundStyle(.red)
                    Text("The target it referenced was removed.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if showWeight {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("weight").font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: Binding(
                        get: { ref.weight },
                        set: { v in var u = ref; u.weight = max(0, v); onUpdate(u) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("quality").font(.caption2).foregroundStyle(.secondary)
                TextField("", value: Binding(
                    get: { ref.qualityOverride ?? resolved?.1.qualityScore ?? 60 },
                    set: { v in var u = ref; u.qualityOverride = v; onUpdate(u) }),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
            }

            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassSurface(.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
        .opacity(ref.enabled ? 1 : 0.55)
    }

    private func detailLine(_ account: ProviderAccount, _ physical: PhysicalModel) -> String {
        var parts = [account.name]
        if let health, health.totalSamples > 0 {
            parts.append("\(Format.percent(health.successRate)) ok")
            if let p = health.ttftP50Seconds ?? health.p50Seconds { parts.append("p50 \(p.msString)") }
        } else {
            parts.append("no traffic yet")
        }
        if let price = physical.pricingOverride, price.isFlatRate {
            parts.append("no marginal cost")
        } else if let blended = physical.pricingOverride?.blendedPerMTok {
            parts.append(String(format: "≈$%.2f/Mtok", blended))
        }
        return parts.joined(separator: " · ")
    }
}

/// Picker for adding provider models to a logical model.
struct AddTargetSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var existing: [TargetRef]
    var onAdd: ([TargetRef]) -> Void

    @State private var chosen: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add targets").font(.title3.weight(.semibold))
                    Text("Any provider model can be a candidate — cloud, subscription or local.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.config.providers) { account in
                        let available = account.models.filter { physical in
                            !existing.contains { $0.providerID == account.id && $0.modelUUID == physical.id }
                        }
                        if !available.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: account.kind.category.symbol)
                                        .foregroundStyle(.secondary)
                                    Text(account.name).font(.headline)
                                    Text(account.kind.displayName)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Select all") {
                                        available.forEach { chosen.insert($0.id) }
                                    }
                                    .buttonStyle(.link).font(.caption)
                                }
                                ForEach(available) { physical in
                                    Toggle(isOn: Binding(
                                        get: { chosen.contains(physical.id) },
                                        set: { on in
                                            if on { chosen.insert(physical.id) } else { chosen.remove(physical.id) }
                                        })) {
                                        HStack(spacing: 8) {
                                            Text(physical.label)
                                                .font(.system(size: 12, design: .monospaced))
                                            Text(physical.effectiveCapabilities.flags.names.joined(separator: " · "))
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if model.config.providers.isEmpty {
                        Text("Add a provider first.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("\(chosen.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .derbyProminentButton()
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
    }

    private func add() {
        var refs: [TargetRef] = []
        for account in model.config.providers {
            for physical in account.models where chosen.contains(physical.id) {
                refs.append(TargetRef(providerID: account.id, modelUUID: physical.id))
            }
        }
        onAdd(refs)
        dismiss()
    }
}
