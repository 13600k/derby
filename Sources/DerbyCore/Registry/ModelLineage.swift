import Foundation

/// Which weights a model id refers to, independent of who serves it or how it
/// was quantized.
///
/// `qwen3.6:27b-q4_K_M` on Ollama, `Qwen/Qwen3.6-27B-FP8` on vLLM and
/// `qwen3.6-27b` behind an OpenAI-compatible endpoint are one model. Derby needs
/// to know that in two places: when a conversation moves between targets
/// (what one model left behind is only meaningful to a model of the same
/// lineage) and when it prefers a copy that is already loaded.
///
/// Parsing is a best-effort reading of the id, the only thing every provider
/// reports. An id it cannot place is `family == "unknown"`, which every caller
/// treats as "assume nothing".
public struct ModelLineage: Codable, Sendable, Hashable {
    /// Lowercased vendor lineage: "qwen", "claude", "gpt", "gemini", "llama", …
    public var family: String
    /// Release within the family: "3.6", "5.1", "4.5", "r1".
    public var generation: String?
    /// Variant that changes the weights: "sonnet", "coder", "vl", "thinking".
    public var tier: String?
    /// Parameter count: "27b", "30b-a3b".
    public var size: String?
    /// How the weights were stored. Never part of identity.
    public var quantization: String?
    /// A local name in front of a known family — `honcho-qwen3.6:27b`, a
    /// Modelfile build of `qwen3.6:27b`. It reads the same template, so what it
    /// writes still means something to that family; it is not the same model,
    /// so it is never treated as an interchangeable copy of the one it came from.
    public var variant: String?

    public init(family: String, generation: String? = nil, tier: String? = nil,
                size: String? = nil, quantization: String? = nil, variant: String? = nil) {
        self.family = family; self.generation = generation; self.tier = tier
        self.size = size; self.quantization = quantization; self.variant = variant
    }

    public static let unknown = ModelLineage(family: "unknown")
    public var isKnown: Bool { family != "unknown" }

    /// Family, generation, tier and size — everything but serving details. A
    /// local build keeps its own identity, so nothing swaps it for the model it
    /// was built from.
    public var identity: String {
        (variant.map { $0 + "@" } ?? "") + [family, generation ?? "", tier ?? "", size ?? ""].joined(separator: "|")
    }

    /// "qwen 3.6 coder 27b", for explanations.
    public var label: String {
        guard isKnown else { return "unknown model family" }
        return [variant, family, generation, tier, size].compactMap { $0 }.joined(separator: " ")
    }

    /// The generation's leading number ("3.6" → 3, "r1" → nil).
    public var majorVersion: Int? {
        guard let generation else { return nil }
        let digits = generation.prefix { $0.isNumber }
        return Int(digits)
    }

    /// The generation as a comparable number ("4.5" → 4.5).
    public var numericVersion: Double? {
        guard let generation else { return nil }
        let prefix = generation.prefix { $0.isNumber || $0 == "." }
        return Double(prefix)
    }

    // MARK: - Affinity

    public func affinity(with other: ModelLineage) -> LineageAffinity {
        guard isKnown, other.isKnown else { return .unknown }
        guard family == other.family else { return .foreign }
        if identity == other.identity { return .identical }
        if generation == other.generation { return .sameFamily }
        return .sameVendor
    }

    // MARK: - Parsing

    /// Reads a lineage from a model id, using a provider-reported family (for
    /// example Ollama's `details.family`) only when the id says nothing.
    public static func parse(_ modelID: String, familyHint: String? = nil) -> ModelLineage {
        var id = modelID.lowercased().trimmingCharacters(in: .whitespaces)
        // "Qwen/Qwen3-32B" and "accounts/fireworks/models/x" name the model last.
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        // Bedrock: "anthropic.claude-sonnet-4-5-20250929-v1:0", "us.anthropic.…".
        for vendor in ["anthropic.", "meta.", "mistral.", "amazon.", "cohere.", "deepseek.", "qwen."] {
            if let range = id.range(of: vendor) { id = String(id[range.upperBound...]); break }
        }
        if let range = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { id.removeSubrange(range) }

        var tokens = id.split(whereSeparator: { "-: ".contains($0) }).map(String.init)
        // Serving noise that never changes the weights.
        let noise: Set<String> = ["latest", "preview", "exp", "experimental", "instruct", "it", "chat",
                                  "hf", "gguf", "mlx", "community", "default"]
        tokens.removeAll { noise.contains($0) || isDateStamp($0) }
        guard let head = tokens.first else { return .unknown }

        var lineage = identifyFamily(head: head, tokens: tokens)
        var variant: String?
        if !lineage.isKnown, tokens.count > 1 {
            // "honcho-qwen3.6:27b": a local build, named in front of the family
            // it was made from. Keep that name, and read the rest as usual.
            for start in 1..<tokens.count {
                var candidate = identifyFamily(head: tokens[start], tokens: Array(tokens[start...]))
                guard candidate.isKnown else { continue }
                candidate.consumed += start
                lineage = candidate
                variant = tokens[0..<start].joined(separator: "-")
                break
            }
        }
        if !lineage.isKnown, let hint = familyHint?.lowercased(), !hint.isEmpty {
            lineage = identifyFamily(head: hint, tokens: [hint] + tokens)
        }
        guard lineage.isKnown else { return .unknown }

        var tierParts: [String] = lineage.tier.map { [$0] } ?? []
        var sizeParts: [String] = []
        var index = lineage.consumed
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if isQuantization(token) {
                lineage.quantization = lineage.quantization ?? token
            } else if isSize(token) {
                sizeParts.append(token)
            } else if lineage.generation == nil, isVersionNumber(token) {
                // "claude-sonnet-4-5": the version follows the tier.
                var version = token
                while index < tokens.count, isVersionNumber(tokens[index]), tokens[index].count <= 2 {
                    version += "." + tokens[index]
                    index += 1
                }
                lineage.generation = version
            } else if lineage.generation != nil, lineage.family == "claude", isVersionNumber(token),
                      token.count <= 2, lineage.generation?.contains(".") == false {
                lineage.generation = (lineage.generation ?? "") + "." + token
            } else if !isVersionNumber(token) {
                tierParts.append(token)
            }
        }
        lineage.size = sizeParts.isEmpty ? nil : sizeParts.joined(separator: "-")
        lineage.tier = tierParts.isEmpty ? nil : tierParts.joined(separator: "-")
        return ModelLineage(family: lineage.family, generation: lineage.generation,
                            tier: lineage.tier, size: lineage.size, quantization: lineage.quantization,
                            variant: variant)
    }

    private struct Partial {
        var family: String
        var generation: String?
        var tier: String?
        var consumed: Int
        var size: String?
        var quantization: String?
        var isKnown: Bool { family != "unknown" }
    }

    /// Known families, most specific prefix first. Each maps a leading token to
    /// a family and whatever version is glued onto it ("qwen3.6" → 3.6).
    private static let families: [(prefix: String, family: String, tier: String?)] = [
        ("gpt-oss", "gpt-oss", nil), ("gptoss", "gpt-oss", nil),
        ("chatgpt", "gpt", nil), ("gpt", "gpt", nil), ("codex", "gpt", "codex"),
        ("claude", "claude", nil), ("opus", "claude", "opus"), ("sonnet", "claude", "sonnet"),
        ("haiku", "claude", "haiku"), ("fable", "claude", "fable"), ("mythos", "claude", "mythos"),
        ("gemini", "gemini", nil), ("gemma", "gemma", nil),
        ("qwq", "qwen", "qwq"), ("qwen", "qwen", nil),
        ("codellama", "llama", "code"), ("llava", "llava", nil), ("llama", "llama", nil),
        ("mixtral", "mistral", "mixtral"), ("ministral", "mistral", "ministral"),
        ("magistral", "mistral", "magistral"), ("devstral", "mistral", "devstral"),
        ("codestral", "mistral", "codestral"), ("pixtral", "mistral", "pixtral"),
        ("mistral", "mistral", nil),
        ("deepseek", "deepseek", nil), ("phi", "phi", nil), ("chatglm", "glm", nil), ("glm", "glm", nil),
        ("kimi", "kimi", nil), ("moonshot", "kimi", nil), ("minimax", "minimax", nil),
        ("grok", "grok", nil), ("command", "command", nil), ("granite", "granite", nil),
        ("nemotron", "nemotron", nil), ("olmo", "olmo", nil), ("hermes", "hermes", nil),
    ]

    private static func identifyFamily(head: String, tokens: [String]) -> Partial {
        // OpenAI reasoning models are named by generation alone: "o3", "o4-mini".
        if head.count <= 3, head.first == "o", head.dropFirst().allSatisfy(\.isNumber), head.count > 1 {
            return Partial(family: "gpt", generation: head, consumed: 1)
        }
        for entry in families where head.hasPrefix(entry.prefix) {
            var rest = String(head.dropFirst(entry.prefix.count))
            var consumed = 1
            // "gpt-oss" arrives split as ["gpt", "oss"].
            if entry.prefix == "gpt-oss" { continue }
            if entry.family == "gpt", head == "gpt", tokens.count > 1, tokens[1] == "oss" {
                return Partial(family: "gpt-oss", consumed: 2)
            }
            while rest.hasPrefix(".") || rest.hasPrefix("_") { rest.removeFirst() }
            var generation: String?
            if !rest.isEmpty {
                // "qwen3.6", "gemma3", "phi4", "llama3.3", "deepseek" + "r1".
                if rest.first?.isNumber == true { generation = rest }
                else if entry.family == "deepseek" || entry.family == "kimi" || entry.family == "minimax" {
                    generation = rest
                }
            }
            if generation == nil, tokens.count > consumed, isVersionNumber(tokens[consumed]),
               entry.family != "claude" {
                // "gemini-2.5-pro", "gpt-5.1", "mistral-7b"… but not a size.
                generation = tokens[consumed]
                consumed += 1
            } else if generation == nil, entry.family == "deepseek", tokens.count > consumed {
                let next = tokens[consumed]
                if next == "r1" || next == "r2" || next.hasPrefix("v") && next.dropFirst().first?.isNumber == true {
                    generation = next
                    consumed += 1
                }
            }
            return Partial(family: entry.family, generation: generation, tier: entry.tier, consumed: consumed)
        }
        return Partial(family: "unknown", consumed: 0)
    }

    static func isDateStamp(_ token: String) -> Bool {
        (token.count == 8 || token.count == 4) && token.allSatisfy(\.isNumber)
            && (token.count == 8 || Int(token).map { $0 >= 2301 && $0 <= 3012 } == true)
    }

    static func isVersionNumber(_ token: String) -> Bool {
        guard let first = token.first, first.isNumber else { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." } && !token.hasSuffix(".")
    }

    static func isSize(_ token: String) -> Bool {
        token.range(of: #"^(a?\d+(\.\d+)?[bm]|\d+x\d+b|e\d+b)$"#, options: .regularExpression) != nil
    }

    static func isQuantization(_ token: String) -> Bool {
        token.range(of: #"^(i?q\d(_[a-z0-9]+)*|fp\d+|bf\d+|int\d+|awq|gptq|\d+bit|nvfp4|mxfp4|exl\d|dwq)$"#,
                    options: .regularExpression) != nil
    }
}

/// How closely two models are related, strongest first.
public enum LineageAffinity: String, Codable, Sendable, Hashable {
    /// Same weights: only quantization, precision or the server differs.
    case identical
    /// Same family and release, different size or variant.
    case sameFamily = "same_family"
    /// Same family, different release.
    case sameVendor = "same_vendor"
    /// Different model families.
    case foreign
    /// At least one side could not be identified.
    case unknown

    var strength: Int {
        switch self {
        case .identical: return 4
        case .sameFamily: return 3
        case .sameVendor: return 2
        case .foreign: return 1
        case .unknown: return 0
        }
    }

    /// Whether a model can use what the other left behind in its own terms.
    public var sharesReasoningFormat: Bool { self == .identical || self == .sameFamily }

    public var displayName: String {
        switch self {
        case .identical: return "same model"
        case .sameFamily: return "same model family"
        case .sameVendor: return "same vendor, different release"
        case .foreign: return "different model family"
        case .unknown: return "unknown model"
        }
    }
}

/// Which prior-turn reasoning a family's own chat template or API reads back.
public enum ReasoningReplayScope: String, Sendable, Hashable {
    /// Never re-sent (DeepSeek-R1's template strips it; the API rejects it).
    case none
    /// Only the assistant turns after the last user message — a tool loop still
    /// in progress. Qwen3's template, gpt-oss's harmony format, and every
    /// signed-reasoning API work this way.
    case activeToolLoop = "active_tool_loop"
    /// Every turn, whenever tools are in play (DeepSeek thinking mode 400s
    /// otherwise).
    case allTurnsWithTools = "all_turns_with_tools"
}

/// Constraints a family's templates place on conversation shape.
public struct LineageTraits: Sendable, Hashable {
    /// May write reasoning into content as `<think>…</think>` when the server
    /// does not separate it.
    public var inlineThinkTags = false
    /// The template opens `<think>` itself, so output begins inside the
    /// reasoning and only `</think>` appears.
    public var thinkTagPrefilled = false
    public var reasoningReplay: ReasoningReplayScope = .none
    /// Tool call ids must be exactly nine alphanumerics (Mistral).
    public var requiresNineCharToolIDs = false
    /// System instructions must all come first.
    public var systemMessagesLeadOnly = false
    /// The template has no system role; instructions ride on the first user turn.
    public var foldsSystemIntoFirstUser = false
    /// user/assistant must alternate strictly.
    public var requiresAlternation = false
    /// `chat_template_kwargs` switch that turns thinking on or off on
    /// self-hosted servers (vLLM, SGLang, llama.cpp).
    public var thinkingTemplateSwitch: String?
    /// The value that switch takes to turn thinking *on* (DeepSeek's defaults off).
    public var thinkingSwitchDefaultsOn = true

    public static func `for`(_ lineage: ModelLineage) -> LineageTraits {
        var t = LineageTraits()
        let major = lineage.majorVersion
        switch lineage.family {
        case "qwen":
            if lineage.tier?.contains("qwq") == true || (major ?? 0) >= 3 {
                t.inlineThinkTags = true
                t.reasoningReplay = .activeToolLoop
                t.thinkTagPrefilled = lineage.tier?.contains("thinking") == true
                if lineage.tier?.contains("qwq") != true, lineage.tier?.contains("thinking") != true,
                   lineage.tier?.contains("instruct") != true {
                    t.thinkingTemplateSwitch = "enable_thinking"
                }
            }
        case "deepseek":
            if lineage.generation == "r1" {
                t.inlineThinkTags = true
                t.reasoningReplay = .none
            } else {
                t.reasoningReplay = .allTurnsWithTools
                if lineage.generation?.hasPrefix("v3") == true {
                    t.inlineThinkTags = true
                    t.thinkingTemplateSwitch = "thinking"
                    t.thinkingSwitchDefaultsOn = false
                }
            }
        case "gpt-oss":
            t.reasoningReplay = .activeToolLoop
        case "glm", "minimax", "kimi":
            t.inlineThinkTags = true
            t.reasoningReplay = .activeToolLoop
        case "claude", "gemini", "gpt":
            // Carried as signed or encrypted artifacts, which only their own
            // APIs read, and only within the turn that produced them.
            t.reasoningReplay = .activeToolLoop
        case "mistral":
            t.requiresNineCharToolIDs = true
            t.systemMessagesLeadOnly = true
            t.requiresAlternation = true
        case "gemma":
            t.requiresAlternation = true
            t.foldsSystemIntoFirstUser = (major ?? 3) < 3
        default:
            break
        }
        return t
    }
}
