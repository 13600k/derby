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

    public static let allNames: [(CapabilityFlags, String)] = [
        (.text, "text"), (.vision, "vision"), (.audioInput, "audio-input"),
        (.audioOutput, "audio-output"), (.tools, "tools"), (.parallelTools, "parallel-tools"),
        (.jsonMode, "json-mode"), (.jsonSchema, "json-schema"), (.reasoning, "reasoning"),
        (.embeddings, "embeddings"), (.streaming, "streaming"),
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

/// Everything Derby knows about what a physical model can do.
public struct ModelCapabilities: Codable, Sendable, Hashable {
    public var flags: CapabilityFlags
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    /// Where this metadata came from; user overrides win over discovery.
    public var source: CapabilitySource

    public init(flags: CapabilityFlags = [.text, .streaming],
                contextWindow: Int? = nil,
                maxOutputTokens: Int? = nil,
                source: CapabilitySource = .builtin) {
        self.flags = flags
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.source = source
    }

    public static let unknown = ModelCapabilities(flags: [.text, .streaming], source: .unknown)

    /// Overlay `other` on top of `self`, keeping non-nil values from `other`.
    public func overridden(by other: PartialCapabilities) -> ModelCapabilities {
        var c = self
        if let f = other.flags { c.flags = f }
        if let cw = other.contextWindow { c.contextWindow = cw }
        if let mo = other.maxOutputTokens { c.maxOutputTokens = mo }
        if other.flags != nil || other.contextWindow != nil || other.maxOutputTokens != nil {
            c.source = .userOverride
        }
        return c
    }
}

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
    public init(flags: CapabilityFlags? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.flags = flags; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
    }
    public var isEmpty: Bool { flags == nil && contextWindow == nil && maxOutputTokens == nil }
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
        if let need = minContextTokens, let have = caps.contextWindow, have > 0, need > have {
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
