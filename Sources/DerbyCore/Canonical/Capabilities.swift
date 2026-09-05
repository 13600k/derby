import Foundation

/// Boolean capability dimensions a physical model may support.
public struct CapabilityFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let text           = CapabilityFlags(rawValue: 1 << 0)
    public static let vision         = CapabilityFlags(rawValue: 1 << 1)
    public static let audioInput     = CapabilityFlags(rawValue: 1 << 2)
    public static let audioOutput    = CapabilityFlags(rawValue: 1 << 3)
    public static let tools          = CapabilityFlags(rawValue: 1 << 4)
    public static let parallelTools  = CapabilityFlags(rawValue: 1 << 5)
    public static let jsonMode       = CapabilityFlags(rawValue: 1 << 6)
    public static let jsonSchema     = CapabilityFlags(rawValue: 1 << 7)
    public static let reasoning      = CapabilityFlags(rawValue: 1 << 8)
    public static let embeddings     = CapabilityFlags(rawValue: 1 << 9)
    public static let streaming      = CapabilityFlags(rawValue: 1 << 10)
    /// Produces images. A model that emits images but not text cannot serve a
    /// chat completion at all, which is a grouping constraint, not a preference.
    public static let imageOutput    = CapabilityFlags(rawValue: 1 << 11)

    /// Input/output modalities. Treated specially when merging metadata: a
    /// modality is only ever claimed when a source actually asserts it.
    public static let allModalities: CapabilityFlags = [.vision, .audioInput, .audioOutput, .imageOutput]

    /// What a model accepts.
    public var inputModalities: [String] {
        var out = ["text"]
        if contains(.vision) { out.append("image") }
        if contains(.audioInput) { out.append("audio") }
        return out
    }

    /// What a model produces. A model that emits no text cannot answer a chat
    /// request, whatever else it can do.
    public var outputModalities: [String] {
        var out: [String] = []
        if contains(.text) { out.append("text") }
        if contains(.imageOutput) { out.append("image") }
        if contains(.audioOutput) { out.append("audio") }
        if out.isEmpty && contains(.embeddings) { out.append("embedding") }
        return out
    }

    /// Whether this model can serve a chat/completions request at all.
    public var canServeText: Bool { contains(.text) }

    public static let allNames: [(CapabilityFlags, String)] = [
        (.text, "text"), (.vision, "vision"), (.audioInput, "audio-input"),
        (.audioOutput, "audio-output"), (.tools, "tools"), (.parallelTools, "parallel-tools"),
        (.jsonMode, "json-mode"), (.jsonSchema, "json-schema"), (.reasoning, "reasoning"),
        (.embeddings, "embeddings"), (.streaming, "streaming"), (.imageOutput, "image-output"),
    ]

    public var names: [String] { Self.allNames.filter { contains($0.0) }.map { $0.1 } }

    public init(names: [String]) {
        var f = CapabilityFlags()
        let table = Dictionary(uniqueKeysWithValues: Self.allNames.map { ($0.1, $0.0) })
        for n in names { if let v = table[n] { f.insert(v) } }
        self = f
    }

    /// Human label for a single flag (used in routing explanations).
    public var label: String { names.joined(separator: ", ") }
}

extension CapabilityFlags {
    /// Codable as an array of stable string names so persisted config survives
    /// re-ordering of the bit definitions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let names = try? c.decode([String].self) { self.init(names: names) }
        else { self.init(rawValue: try c.decode(Int.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}

/// Request parameters a model may or may not accept.
///
/// Capability flags describe what a model *can do*; this describes what it will
/// *tolerate being sent*. The two are independent: reasoning-era models are
/// highly capable yet reject `temperature` outright, and a request carrying one
/// fails with a deprecation error rather than being ignored.
public struct RequestParameters: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let temperature       = RequestParameters(rawValue: 1 << 0)
    public static let topP              = RequestParameters(rawValue: 1 << 1)
    public static let topK              = RequestParameters(rawValue: 1 << 2)
    public static let maxTokens         = RequestParameters(rawValue: 1 << 3)
    public static let stop              = RequestParameters(rawValue: 1 << 4)
    public static let seed              = RequestParameters(rawValue: 1 << 5)
    public static let frequencyPenalty  = RequestParameters(rawValue: 1 << 6)
    public static let presencePenalty   = RequestParameters(rawValue: 1 << 7)
    public static let logprobs          = RequestParameters(rawValue: 1 << 8)
    public static let responseFormat    = RequestParameters(rawValue: 1 << 9)
    public static let toolChoice        = RequestParameters(rawValue: 1 << 10)
    public static let parallelToolCalls = RequestParameters(rawValue: 1 << 11)
    public static let reasoningEffort   = RequestParameters(rawValue: 1 << 12)

    public static let allNames: [(RequestParameters, String)] = [
        (.temperature, "temperature"), (.topP, "top_p"), (.topK, "top_k"),
        (.maxTokens, "max_tokens"), (.stop, "stop"), (.seed, "seed"),
        (.frequencyPenalty, "frequency_penalty"), (.presencePenalty, "presence_penalty"),
        (.logprobs, "logprobs"), (.responseFormat, "response_format"),
        (.toolChoice, "tool_choice"), (.parallelToolCalls, "parallel_tool_calls"),
        (.reasoningEffort, "reasoning_effort"),
    ]

    /// The set a source enumerating parameters is understood to be choosing from.
    public static let known: RequestParameters = [
        .temperature, .topP, .topK, .maxTokens, .stop, .seed, .frequencyPenalty,
        .presencePenalty, .logprobs, .responseFormat, .toolChoice, .parallelToolCalls,
        .reasoningEffort,
    ]

    public var names: [String] { Self.allNames.filter { contains($0.0) }.map { $0.1 } }

    public init(names: [String]) {
        let table = Dictionary(uniqueKeysWithValues: Self.allNames.map { ($0.1, $0.0) })
        var out = RequestParameters()
        for name in names {
            if let value = table[name] { out.insert(value) }
            // Aliases used by various providers' own vocabularies.
            switch name {
            case "structured_outputs", "json_schema": out.insert(.responseFormat)
            case "reasoning", "include_reasoning", "thinking": out.insert(.reasoningEffort)
            case "max_completion_tokens", "max_output_tokens": out.insert(.maxTokens)
            case "stop_sequences": out.insert(.stop)
            default: break
            }
        }
        self = out
    }

    // Encoded as stable names so persisted config survives bit re-ordering.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let names = try? c.decode([String].self) { self.init(names: names) }
        else { self.init(rawValue: try c.decode(Int.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}

/// Everything Derby knows about what a physical model can do.
///
/// Deliberately limited to what the router *acts on*: capability filtering,
/// context fitting and embedding compatibility. Descriptive facts that do not
/// change a routing decision live in `ModelProfile` instead.
public struct ModelCapabilities: Codable, Sendable, Hashable {
    public var flags: CapabilityFlags
    /// Total context the model can hold, prompt plus completion.
    public var contextWindow: Int?
    /// Largest completion the model will produce.
    public var maxOutputTokens: Int?
    /// Largest prompt the model accepts, when a provider states it separately
    /// from the total context window.
    public var maxInputTokens: Int?
    /// Vector width, for embedding models.
    public var embeddingDimensions: Int?
    /// Parameters this model is known to reject. A deny-list, so a model nothing
    /// is known about still receives every parameter, exactly as before.
    public var unsupportedParameters: RequestParameters
    /// Reasoning effort levels this model accepts, when a source enumerates them.
    public var supportedReasoningEfforts: [String]?
    /// Where this metadata came from; user overrides win over discovery.
    public var source: CapabilitySource

    public init(flags: CapabilityFlags = [.text, .streaming],
                contextWindow: Int? = nil,
                maxOutputTokens: Int? = nil,
                maxInputTokens: Int? = nil,
                embeddingDimensions: Int? = nil,
                unsupportedParameters: RequestParameters = [],
                supportedReasoningEfforts: [String]? = nil,
                source: CapabilitySource = .builtin) {
        self.flags = flags
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.maxInputTokens = maxInputTokens
        self.embeddingDimensions = embeddingDimensions
        self.unsupportedParameters = unsupportedParameters
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.source = source
    }

    /// Whether a parameter may be sent. Unknown models allow everything, so this
    /// can only ever remove a parameter a provider would have rejected.
    public func allows(_ parameter: RequestParameters) -> Bool {
        !unsupportedParameters.contains(parameter)
    }

    /// Clamps a requested effort to the strongest level this model accepts.
    public func clampEffort(_ effort: ReasoningEffort) -> String? {
        guard let levels = supportedReasoningEfforts, !levels.isEmpty else { return effort.rawValue }
        if levels.contains(effort.rawValue) { return effort.rawValue }
        for candidate in ReasoningEffort.descendingFrom(effort) where levels.contains(candidate.rawValue) {
            return candidate.rawValue
        }
        // Some vocabularies use "none" where Derby says "minimal".
        if levels.contains("none") { return "none" }
        return levels.first
    }

    // Decoded field by field, every one optional.
    //
    // This type is persisted inside every configured model, so adding a
    // non-optional property to it silently broke decoding of the whole
    // `providers` array — and the tolerant `try?` above turned that into five
    // providers vanishing without a word. New fields must always default.
    private enum CodingKeys: String, CodingKey {
        case flags, contextWindow, maxOutputTokens, maxInputTokens
        case embeddingDimensions, unsupportedParameters, supportedReasoningEfforts, source
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flags = (try? c.decode(CapabilityFlags.self, forKey: .flags)) ?? [.text, .streaming]
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        maxInputTokens = try c.decodeIfPresent(Int.self, forKey: .maxInputTokens)
        embeddingDimensions = try c.decodeIfPresent(Int.self, forKey: .embeddingDimensions)
        unsupportedParameters = (try? c.decode(RequestParameters.self, forKey: .unsupportedParameters)) ?? []
        supportedReasoningEfforts = try c.decodeIfPresent([String].self, forKey: .supportedReasoningEfforts)
        source = (try? c.decode(CapabilitySource.self, forKey: .source)) ?? .unknown
    }

    /// The prompt ceiling to filter against: an explicit input limit if the
    /// provider gave one, otherwise the whole context window.
    public var effectiveInputLimit: Int? { maxInputTokens ?? contextWindow }

    /// Fills in facts this value does not have from `other`, keeping everything
    /// it does. Discovery states some things and not others, so a discovered
    /// capability set is completed from the bundled catalog rather than
    /// discarding the catalog or overwriting live data with it.
    public func fillingGaps(from other: ModelCapabilities) -> ModelCapabilities {
        var merged = self
        merged.flags.formUnion(other.flags.subtracting(.allModalities))
        // Modalities are asserted, never inherited: claiming vision a model
        // lacks turns into a hard failure at request time.
        if flags.isDisjoint(with: .allModalities) {
            merged.flags.formUnion(other.flags.intersection(.allModalities))
        }
        merged.contextWindow = contextWindow ?? other.contextWindow
        merged.maxOutputTokens = maxOutputTokens ?? other.maxOutputTokens
        merged.maxInputTokens = maxInputTokens ?? other.maxInputTokens
        merged.embeddingDimensions = embeddingDimensions ?? other.embeddingDimensions
        merged.unsupportedParameters.formUnion(other.unsupportedParameters)
        merged.supportedReasoningEfforts = supportedReasoningEfforts ?? other.supportedReasoningEfforts
        return merged
    }

    /// What is still unknown, for the UI to prompt about.
    public var missingFacts: [String] {
        var missing: [String] = []
        if contextWindow == nil { missing.append("context window") }
        if maxOutputTokens == nil { missing.append("max output") }
        if flags.contains(.embeddings) && embeddingDimensions == nil { missing.append("dimensions") }
        return missing
    }

    public static let unknown = ModelCapabilities(flags: [.text, .streaming], source: .unknown)

    /// Fills in only what this value does not know, from Derby's bundled
    /// catalog.
    ///
    /// Discovery tells us which *features* a model has but almost never how big
    /// its context window is — a provider's model list rarely says. Choosing
    /// wholesale between discovery and the catalog therefore left every
    /// discovered model with no context window at all, which made
    /// `minContextTokens` filtering and `failoverToLargerContext` inert and gave
    /// clients nothing to size a conversation with.
    public func completed(by fallback: ModelCapabilities) -> ModelCapabilities {
        var c = self
        if c.flags.isEmpty { c.flags = fallback.flags }
        if c.contextWindow == nil { c.contextWindow = fallback.contextWindow }
        if c.maxOutputTokens == nil { c.maxOutputTokens = fallback.maxOutputTokens }
        if c.maxInputTokens == nil { c.maxInputTokens = fallback.maxInputTokens }
        if c.embeddingDimensions == nil { c.embeddingDimensions = fallback.embeddingDimensions }
        // A parameter either source knows to be rejected stays rejected: sending
        // one is a hard error, so the union is the safe combination.
        c.unsupportedParameters.formUnion(fallback.unsupportedParameters)
        if c.supportedReasoningEfforts == nil { c.supportedReasoningEfforts = fallback.supportedReasoningEfforts }
        return c
    }

    /// Overlay `other` on top of `self`, keeping non-nil values from `other`.
    public func overridden(by other: PartialCapabilities) -> ModelCapabilities {
        var c = self
        if let f = other.flags { c.flags = f }
        if let cw = other.contextWindow { c.contextWindow = cw }
        if let mo = other.maxOutputTokens { c.maxOutputTokens = mo }
        if let mi = other.maxInputTokens { c.maxInputTokens = mi }
        if let ed = other.embeddingDimensions { c.embeddingDimensions = ed }
        if !other.isEmpty { c.source = .userOverride }
        return c
    }
}

/// Where a model's capability *flags* came from. Context window and max output
/// may still have been completed from the bundled catalog — see
/// `ModelCapabilities.completed(by:)`.
public enum CapabilitySource: String, Codable, Sendable, Hashable {
    case builtin        // Derby's bundled model metadata
    case discovered     // learned from a provider listModels / probe
    case userOverride   // explicitly set by the user
    case unknown        // nothing known; assume conservative defaults
}

/// A sparse capability override supplied by the user in the UI.
public struct PartialCapabilities: Codable, Sendable, Hashable {
    public var flags: CapabilityFlags?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var maxInputTokens: Int?
    public var embeddingDimensions: Int?
    public init(flags: CapabilityFlags? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
                maxInputTokens: Int? = nil, embeddingDimensions: Int? = nil) {
        self.flags = flags; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
        self.maxInputTokens = maxInputTokens; self.embeddingDimensions = embeddingDimensions
    }
    public var isEmpty: Bool {
        flags == nil && contextWindow == nil && maxOutputTokens == nil
            && maxInputTokens == nil && embeddingDimensions == nil
    }
}

/// Descriptive facts about a model that do not change a routing decision but
/// help a person judge it: size, quantization, family, provenance.
///
/// Kept apart from `ModelCapabilities` on purpose — the router reads
/// capabilities on every request and should not carry display data.
public struct ModelProfile: Codable, Sendable, Hashable {
    public var family: String?
    public var parameterSize: String?      // "27.8B"
    public var quantization: String?       // "Q4_K_M"
    public var format: String?             // "gguf"
    public var diskSizeBytes: Int?
    public var summary: String?
    public var ownedBy: String?
    public var version: String?
    public var modifiedAt: Date?

    public init(family: String? = nil, parameterSize: String? = nil, quantization: String? = nil,
                format: String? = nil, diskSizeBytes: Int? = nil, summary: String? = nil,
                ownedBy: String? = nil, version: String? = nil, modifiedAt: Date? = nil) {
        self.family = family; self.parameterSize = parameterSize; self.quantization = quantization
        self.format = format; self.diskSizeBytes = diskSizeBytes; self.summary = summary
        self.ownedBy = ownedBy; self.version = version; self.modifiedAt = modifiedAt
    }

    public var isEmpty: Bool {
        family == nil && parameterSize == nil && quantization == nil && format == nil
            && diskSizeBytes == nil && summary == nil && ownedBy == nil && version == nil
    }

    /// Compact one-line description for the model list.
    public var descriptors: [String] {
        var parts: [String] = []
        if let parameterSize { parts.append(parameterSize) }
        if let quantization { parts.append(quantization) }
        if let family { parts.append(family) }
        if let diskSizeBytes, diskSizeBytes > 0 {
            parts.append(String(format: "%.1f GB", Double(diskSizeBytes) / 1_073_741_824))
        }
        return parts
    }
}

/// What a specific request needs from a target in order to be routable to it.
public struct CapabilityRequirements: Sendable, Hashable, Codable {
    public var required: CapabilityFlags
    /// Estimated prompt tokens; a target whose context window is smaller is filtered out.
    public var minContextTokens: Int?
    /// Requested max output tokens.
    public var minOutputTokens: Int?

    public init(required: CapabilityFlags = [.text],
                minContextTokens: Int? = nil,
                minOutputTokens: Int? = nil) {
        self.required = required
        self.minContextTokens = minContextTokens
        self.minOutputTokens = minOutputTokens
    }

    /// Returns nil when satisfied, or a human-readable reason for exclusion.
    public func unmetReason(for caps: ModelCapabilities) -> String? {
        let missing = required.subtracting(caps.flags)
        if !missing.isEmpty { return "\(missing.label) unsupported" }
        if let need = minContextTokens, let have = caps.effectiveInputLimit, have > 0, need > have {
            return "context window too small (needs ~\(need.formattedTokens), has \(have.formattedTokens))"
        }
        if let need = minOutputTokens, let have = caps.maxOutputTokens, have > 0, need > have {
            return "max output too small (needs \(need.formattedTokens), has \(have.formattedTokens))"
        }
        return nil
    }
}

extension Int {
    public var formattedTokens: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return "\(self / 1000)k" }
        return "\(self)"
    }
}
