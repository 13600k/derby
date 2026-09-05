import SwiftUI
import DerbyCore

struct NumberField: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100000
    var onCommit: () -> Void

    init(label: String, value: Binding<Double>, range: ClosedRange<Double>, onCommit: @escaping () -> Void) {
        self.label = label; self._value = value; self.range = range; self.onCommit = onCommit
    }
    init(label: String, value: Binding<Int>, range: ClosedRange<Int>, onCommit: @escaping () -> Void) {
        self.label = label
        self._value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    value = min(max(value, range.lowerBound), range.upperBound)
                    onCommit()
                }
        }
    }
}

struct OptionalNumberField: View {
    var label: String
    @Binding var value: Int?
    var onCommit: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("unlimited", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onAppear { text = value.map(String.init) ?? "" }
                .onChange(of: value) { _, newValue in
                    let expected = newValue.map(String.init) ?? ""
                    if expected != text { text = expected }
                }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        value = trimmed.isEmpty ? nil : Int(trimmed)
        text = value.map(String.init) ?? ""
        onCommit()
    }
}

struct OptionalDoubleField: View {
    var label: String
    @Binding var value: Double?
    var placeholder = "unlimited"
    var onCommit: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onAppear { text = value.map { String($0) } ?? "" }
                .onChange(of: value) { _, newValue in
                    let expected = newValue.map { String($0) } ?? ""
                    if expected != text { text = expected }
                }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        value = trimmed.isEmpty ? nil : Double(trimmed)
        text = value.map { String($0) } ?? ""
        onCommit()
    }
}

/// Editor for arbitrary extra request headers.
struct HeaderEditor: View {
    @Binding var headers: [String: String]
    var onCommit: () -> Void
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extra request headers").font(.callout)
            ForEach(headers.keys.sorted(), id: \.self) { key in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 150, alignment: .leading)
                    Text(headers[key] ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        headers.removeValue(forKey: key)
                        onCommit()
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                TextField("Header", text: $newKey)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("Value", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let key = newKey.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    headers[key] = newValue
                    newKey = ""; newValue = ""
                    onCommit()
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// One row in a provider's model list, with inline capability and pricing edits.
struct ModelRow: View {
    var account: ProviderAccount
    var physical: PhysicalModel
    var health: TargetHealth
    var isProbing: Bool
    var onToggle: (Bool) -> Void
    var onQuality: (Double) -> Void
    var onContext: (Int?) -> Void
    var onMaxOutput: (Int?) -> Void
    var onPricing: (Pricing?) -> Void
    var onProbe: () -> Void
    var onRemove: () -> Void
    var onResetCircuit: () -> Void

    @State private var expanded = false

    private var caps: ModelCapabilities { physical.effectiveCapabilities }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { physical.enabled }, set: onToggle))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(physical.label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if health.circuit == .open {
                            StatusPill(text: "CIRCUIT OPEN", tint: .red, systemImage: "bolt.slash")
                        } else if health.state != .unknown {
                            StatusPill(text: health.state.rawValue, tint: health.state.tint)
                        }
                    }
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)

                if isProbing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { onProbe() }
                        .buttonStyle(.borderless)
                        .help("Send one tiny completion to this model")
                }
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                Button { onRemove() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)

            if expanded { detail }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let window = caps.contextWindow { parts.append("\(window.formattedTokens) ctx") }
        if let out = caps.maxOutputTokens { parts.append("\(out.formattedTokens) out") }
        if let dimensions = caps.embeddingDimensions { parts.append("\(dimensions)-dim") }
        parts.append(contentsOf: physical.profile?.descriptors ?? [])
        if !caps.flags.names.isEmpty { parts.append(caps.flags.names.joined(separator: "/")) }
        if health.totalSamples > 0 {
            parts.append("\(Format.percent(health.successRate)) ok")
            if let p = health.p50Seconds { parts.append("p50 \(p.msString)") }
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Named so the user can fill in what discovery could not establish, rather
    /// than a silently blank field.
    private var missingFacts: [String] { caps.missingFacts }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // What the model *is* comes from the provider and is not editable
            // here. Narrowing belongs to a logical model, where it is a policy
            // decision about the contract that group presents.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Reported by the provider").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(text: sourceLabel, tint: sourceTint)
                }
                FlowLayout(spacing: 5) {
                    ForEach(caps.flags.names, id: \.self) { name in
                        Text(name)
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                HStack(spacing: 16) {
                    factView("Context window", caps.contextWindow.map { $0.formattedTokens })
                    factView("Max output", caps.maxOutputTokens.map { $0.formattedTokens })
                    if caps.flags.contains(.embeddings) {
                        factView("Dimensions", caps.embeddingDimensions.map(String.init))
                    }
                    Spacer()
                }
                if !caps.unsupportedParameters.isEmpty {
                    Text("Rejects: \(caps.unsupportedParameters.names.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Derby omits these from requests to this model.")
                }
                if let efforts = caps.supportedReasoningEfforts, !efforts.isEmpty {
                    Text("Reasoning levels: \(efforts.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let profile = physical.profile, !profile.descriptors.isEmpty {
                    Text(profile.descriptors.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let summary = physical.profile?.summary {
                    Text(summary).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Use Discover Models to refresh these from the provider. To offer less than a model supports, narrow the logical model that uses it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The one exception: a provider that reported nothing leaves Derby
            // guessing, and there would otherwise be no way to correct it.
            if !missingFacts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(physical.modelID) did not report: \(missingFacts.joined(separator: ", ")).",
                          systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Routing still works — an unknown limit is never used to exclude a model — but supplying it lets Derby fit conversations to this model.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if caps.contextWindow == nil {
                            OptionalNumberField(label: "Context window (tokens)",
                                                value: Binding(get: { caps.contextWindow }, set: onContext)) {}
                                .frame(width: 180)
                        }
                        if caps.maxOutputTokens == nil {
                            OptionalNumberField(label: "Max output (tokens)",
                                                value: Binding(get: { caps.maxOutputTokens }, set: onMaxOutput)) {}
                                .frame(width: 160)
                        }
                        Spacer()
                    }
                }
            }

            Divider()

            // What a person legitimately decides about a model.
            VStack(alignment: .leading, spacing: 4) {
                Text("Intelligence score: \(Int(physical.qualityScore))").font(.callout)
                Slider(value: Binding(get: { physical.qualityScore }, set: onQuality), in: 0...100, step: 1)
                Text("Your ranking of this model's quality, used by weighted-score routing.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                OptionalDoubleField(label: "Input $/Mtok",
                                    value: Binding(
                                        get: { physical.pricingOverride?.inputPerMTok },
                                        set: { newValue in
                                            var p = physical.pricingOverride ?? Pricing()
                                            p.inputPerMTok = newValue
                                            onPricing(p)
                                        }),
                                    placeholder: "unknown") {}
                    .frame(width: 130)
                OptionalDoubleField(label: "Output $/Mtok",
                                    value: Binding(
                                        get: { physical.pricingOverride?.outputPerMTok },
                                        set: { newValue in
                                            var p = physical.pricingOverride ?? Pricing()
                                            p.outputPerMTok = newValue
                                            onPricing(p)
                                        }),
                                    placeholder: "unknown") {}
                    .frame(width: 130)
                OptionalDoubleField(label: "Cached input $/Mtok",
                                    value: Binding(
                                        get: { physical.pricingOverride?.cachedInputPerMTok },
                                        set: { newValue in
                                            var p = physical.pricingOverride ?? Pricing()
                                            p.cachedInputPerMTok = newValue
                                            onPricing(p)
                                        }),
                                    placeholder: "unknown") {}
                    .frame(width: 150)
                Spacer()
            }
            if physical.pricingOverride?.isFlatRate == true {
                Text("Local and subscription targets are flat-rate: no marginal cost per token.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if health.totalSamples > 0 || health.circuit != .closed {
                Divider()
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Measured by Derby").font(.caption).foregroundStyle(.secondary)
                        Text(health.summaryLine).font(.caption)
                        if let failure = health.lastFailureMessage, health.lastFailureAt != nil {
                            Text(failure).font(.caption2).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                    if health.circuit != .closed {
                        Button("Reset circuit") { onResetCircuit() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func factView(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value ?? "not reported")
                .font(.callout.weight(.medium))
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }

    private var sourceLabel: String {
        switch caps.source {
        case .discovered: return "FROM PROVIDER"
        case .builtin: return "KNOWN MODEL"
        case .userOverride: return "SET BY YOU"
        case .unknown: return "NOT REPORTED"
        }
    }
    private var sourceTint: Color {
        switch caps.source {
        case .discovered: return .green
        case .builtin: return .accentColor
        case .userOverride: return .orange
        case .unknown: return .secondary
        }
    }
}

/// Wraps children onto multiple lines — used for capability chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
