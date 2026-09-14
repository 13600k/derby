import Foundation

/// Bundled metadata about well-known models: capabilities, context window and
/// list pricing. Everything here is a *default* — discovery and user overrides
/// both win, and a miss is never fatal (unknown models simply route with
/// conservative capabilities and no cost signal).
public enum ModelCatalog {

    public struct Entry: Sendable {
        public var pattern: String          // matched case-insensitively as a substring
        public var flags: CapabilityFlags
        public var context: Int?
        public var maxOutput: Int?
        public var pricing: Pricing?
        public var quality: Double

        init(_ pattern: String, _ flags: CapabilityFlags, context: Int? = nil, maxOutput: Int? = nil,
             input: Double? = nil, output: Double? = nil, cached: Double? = nil, quality: Double = 60) {
            self.pattern = pattern
            self.flags = flags
            self.context = context
            self.maxOutput = maxOutput
            self.pricing = (input != nil || output != nil)
                ? Pricing(inputPerMTok: input, outputPerMTok: output, cachedInputPerMTok: cached)
                : nil
            self.quality = quality
        }
    }

    private static let chat: CapabilityFlags = [.text, .streaming, .tools, .parallelTools, .jsonMode, .jsonSchema]
    private static let chatVision: CapabilityFlags = [.text, .streaming, .tools, .parallelTools, .jsonMode, .jsonSchema, .vision]
    private static let reasoningVision: CapabilityFlags = [.text, .streaming, .tools, .parallelTools, .jsonMode, .jsonSchema, .vision, .reasoning]
    private static let embed: CapabilityFlags = [.embeddings]

    /// Ordered most-specific first; the longest matching pattern wins.
    public static let entries: [Entry] = [
        // ---- OpenAI ----
        Entry("gpt-5.1-codex", reasoningVision, context: 400_000, maxOutput: 128_000, input: 1.25, output: 10, cached: 0.125, quality: 95),
        Entry("gpt-5.1-mini", reasoningVision, context: 400_000, maxOutput: 128_000, input: 0.25, output: 2, cached: 0.025, quality: 82),
        Entry("gpt-5.1", reasoningVision, context: 400_000, maxOutput: 128_000, input: 1.25, output: 10, cached: 0.125, quality: 95),
        Entry("gpt-5-mini", reasoningVision, context: 400_000, maxOutput: 128_000, input: 0.25, output: 2, cached: 0.025, quality: 80),
        Entry("gpt-5-nano", reasoningVision, context: 400_000, maxOutput: 128_000, input: 0.05, output: 0.4, cached: 0.005, quality: 68),
        Entry("gpt-5", reasoningVision, context: 400_000, maxOutput: 128_000, input: 1.25, output: 10, cached: 0.125, quality: 93),
        Entry("gpt-4.1-nano", chatVision, context: 1_047_576, maxOutput: 32_768, input: 0.1, output: 0.4, cached: 0.025, quality: 62),
        Entry("gpt-4.1-mini", chatVision, context: 1_047_576, maxOutput: 32_768, input: 0.4, output: 1.6, cached: 0.1, quality: 74),
        Entry("gpt-4.1", chatVision, context: 1_047_576, maxOutput: 32_768, input: 2, output: 8, cached: 0.5, quality: 86),
        Entry("gpt-4o-mini", chatVision, context: 128_000, maxOutput: 16_384, input: 0.15, output: 0.6, cached: 0.075, quality: 65),
        Entry("gpt-4o", chatVision, context: 128_000, maxOutput: 16_384, input: 2.5, output: 10, cached: 1.25, quality: 80),
        Entry("o4-mini", reasoningVision, context: 200_000, maxOutput: 100_000, input: 1.1, output: 4.4, cached: 0.275, quality: 84),
        Entry("o3-mini", [.text, .streaming, .tools, .jsonSchema, .reasoning], context: 200_000, maxOutput: 100_000, input: 1.1, output: 4.4, quality: 78),
        Entry("o3", reasoningVision, context: 200_000, maxOutput: 100_000, input: 2, output: 8, cached: 0.5, quality: 90),
        Entry("text-embedding-3-large", embed, context: 8_191, input: 0.13, quality: 70),
        Entry("text-embedding-3-small", embed, context: 8_191, input: 0.02, quality: 60),

        // ---- Anthropic ----
        Entry("claude-opus-4-5", reasoningVision, context: 200_000, maxOutput: 64_000, input: 5, output: 25, cached: 0.5, quality: 97),
        Entry("claude-opus-4-1", reasoningVision, context: 200_000, maxOutput: 32_000, input: 15, output: 75, cached: 1.5, quality: 95),
        Entry("claude-opus-4", reasoningVision, context: 200_000, maxOutput: 32_000, input: 15, output: 75, cached: 1.5, quality: 94),
        Entry("claude-sonnet-4-5", reasoningVision, context: 200_000, maxOutput: 64_000, input: 3, output: 15, cached: 0.3, quality: 93),
        Entry("claude-sonnet-4", reasoningVision, context: 200_000, maxOutput: 64_000, input: 3, output: 15, cached: 0.3, quality: 90),
        Entry("claude-haiku-4-5", reasoningVision, context: 200_000, maxOutput: 64_000, input: 1, output: 5, cached: 0.1, quality: 80),
        Entry("claude-3-7-sonnet", reasoningVision, context: 200_000, maxOutput: 64_000, input: 3, output: 15, cached: 0.3, quality: 85),
        Entry("claude-3-5-haiku", chatVision, context: 200_000, maxOutput: 8_192, input: 0.8, output: 4, cached: 0.08, quality: 70),
        Entry("claude-3-5-sonnet", chatVision, context: 200_000, maxOutput: 8_192, input: 3, output: 15, cached: 0.3, quality: 82),

        // ---- Google ----
        Entry("gemini-3-pro", reasoningVision, context: 1_048_576, maxOutput: 65_536, input: 2, output: 12, cached: 0.2, quality: 94),
        Entry("gemini-3-flash", reasoningVision, context: 1_048_576, maxOutput: 65_536, input: 0.3, output: 2.5, cached: 0.03, quality: 84),
        Entry("gemini-2.5-pro", reasoningVision, context: 1_048_576, maxOutput: 65_536, input: 1.25, output: 10, cached: 0.31, quality: 90),
        Entry("gemini-2.5-flash-lite", reasoningVision, context: 1_048_576, maxOutput: 65_536, input: 0.1, output: 0.4, quality: 68),
        Entry("gemini-2.5-flash", reasoningVision, context: 1_048_576, maxOutput: 65_536, input: 0.3, output: 2.5, cached: 0.075, quality: 82),
        Entry("gemini-2.0-flash", chatVision, context: 1_048_576, maxOutput: 8_192, input: 0.1, output: 0.4, quality: 72),
        Entry("gemini-embedding", embed, context: 2_048, input: 0.15, quality: 65),
        Entry("text-embedding-004", embed, context: 2_048, input: 0, quality: 60),

        // ---- Other hosted ----
        Entry("deepseek-reasoner", [.text, .streaming, .tools, .jsonMode, .reasoning], context: 128_000, maxOutput: 65_536, input: 0.55, output: 2.19, cached: 0.07, quality: 86),
        Entry("deepseek-chat", chat, context: 128_000, maxOutput: 8_192, input: 0.27, output: 1.1, cached: 0.07, quality: 80),
        Entry("grok-4", reasoningVision, context: 256_000, maxOutput: 32_768, input: 3, output: 15, quality: 88),
        Entry("grok-3-mini", [.text, .streaming, .tools, .jsonSchema, .reasoning], context: 131_072, input: 0.3, output: 0.5, quality: 72),
        Entry("grok-3", chatVision, context: 131_072, input: 3, output: 15, quality: 84),
        Entry("mistral-large", chat, context: 131_072, input: 2, output: 6, quality: 78),
        Entry("mistral-small", chat, context: 131_072, input: 0.1, output: 0.3, quality: 66),
        Entry("codestral", chat, context: 262_144, input: 0.3, output: 0.9, quality: 74),
        Entry("llama-4-maverick", chatVision, context: 1_048_576, input: 0.27, output: 0.85, quality: 78),
        Entry("llama-4-scout", chatVision, context: 327_680, input: 0.11, output: 0.34, quality: 72),
        Entry("llama-3.3-70b", chat, context: 131_072, input: 0.59, output: 0.79, quality: 70),
        Entry("kimi-k2", chat, context: 262_144, input: 0.6, output: 2.5, quality: 84),
        Entry("glm-4.6", chat, context: 200_000, input: 0.6, output: 2.2, quality: 82),
        Entry("minimax-m2", chat, context: 204_800, input: 0.3, output: 1.2, quality: 80),

        // ---- Qwen ----
        Entry("qwen3-coder-plus", chat, context: 1_048_576, input: 1, output: 5, quality: 86),
        Entry("qwen3-coder", chat, context: 262_144, input: 0.3, output: 1.2, quality: 82),
        Entry("qwen3-max", chatVision, context: 262_144, input: 1.2, output: 6, quality: 88),
        Entry("qwen3-vl", chatVision, context: 262_144, input: 0.3, output: 1.2, quality: 80),
        Entry("qwen-plus", chat, context: 131_072, input: 0.4, output: 1.2, quality: 78),
        Entry("qwen-turbo", chat, context: 1_048_576, input: 0.05, output: 0.2, quality: 66),
        Entry("qwen3-embedding", embed, context: 32_768, quality: 62),
        Entry("qwen3-reranker", [.text], context: 32_768, quality: 55),
        Entry("qwen3.6", reasoningVision, context: 262_144, maxOutput: 32_768, quality: 82),
        Entry("qwen3.5", reasoningVision, context: 262_144, maxOutput: 32_768, quality: 78),
        Entry("qwen3", [.text, .streaming, .tools, .jsonMode, .reasoning], context: 131_072, maxOutput: 32_768, quality: 74),
        Entry("qwq", [.text, .streaming, .tools, .reasoning], context: 131_072, quality: 72),

        // ---- Common local families ----
        Entry("nomic-embed", embed, context: 8_192, quality: 58),
        Entry("mxbai-embed", embed, context: 512, quality: 56),
        Entry("all-minilm", embed, context: 512, quality: 50),
        Entry("embed", embed, context: 8_192, quality: 55),
        Entry("gpt-oss", [.text, .streaming, .tools, .jsonMode, .reasoning], context: 131_072, quality: 76),
        Entry("devstral", chat, context: 131_072, quality: 72),
        Entry("codellama", [.text, .streaming], context: 16_384, quality: 55),
        Entry("deepseek-r1", [.text, .streaming, .reasoning], context: 131_072, quality: 78),
        Entry("phi-4", chat, context: 16_384, quality: 62),
        Entry("gemma3", chatVision, context: 131_072, quality: 66),
        Entry("gemma", [.text, .streaming], context: 8_192, quality: 58),
        Entry("mistral", chat, context: 32_768, quality: 64),
        Entry("llava", [.text, .streaming, .vision], context: 32_768, quality: 55),
        Entry("llama", chat, context: 131_072, quality: 66),
    ]

    /// Best-effort metadata for a model id.
    public static func lookup(_ modelID: String) -> Entry? {
        let id = modelID.lowercased()
        var best: Entry?
        for e in entries where id.contains(e.pattern) {
            if best == nil || e.pattern.count > best!.pattern.count { best = e }
        }
        return best
    }

    /// Tier names a provider may accept in place of a model id.
    static let tierAliases: Set<String> = ["opus", "sonnet", "haiku"]

    /// The newest concrete model in a tier, or nil when `modelID` is not one of
    /// the tier names. The live index decides by release date; the bundled table
    /// is listed newest-first, so its first match is the newest it knows.
    public static func newestInTier(_ modelID: String, kind: ProviderKind) -> String? {
        let tier = modelID.lowercased()
        guard tierAliases.contains(tier) else { return nil }
        if let live = RemoteModelCatalog.shared.newestID(containing: tier, kind: kind) { return live }
        return entries.first { $0.pattern.contains(tier) }?.pattern
    }

    /// Capabilities + pricing + quality for a model on a given provider kind.
    ///
    /// Order of authority: the live `models.dev` index first, because a
    /// hand-written table always trails the models people actually run; then the
    /// bundled patterns below; then a conservative unknown. Whichever source
    /// answers, gaps are filled from the next one down rather than left blank.
    public static func metadata(for modelID: String, kind: ProviderKind)
        -> (capabilities: ModelCapabilities, pricing: Pricing?, quality: Double) {

        // An alias the provider resolves for itself describes whichever model it
        // currently runs, so answer for that model rather than for a name no
        // catalog lists.
        if kind.resolvesTierAliases, let resolved = newestInTier(modelID, kind: kind) {
            return metadata(for: resolved, kind: kind)
        }

        let bundled = lookup(modelID)

        if let live = RemoteModelCatalog.shared.lookup(modelID, kind: kind) {
            var capabilities = live.capabilities
            if let fallback = bundled {
                capabilities = capabilities.fillingGaps(
                    from: ModelCapabilities(flags: fallback.flags,
                                            contextWindow: fallback.context,
                                            maxOutputTokens: fallback.maxOutput,
                                            source: .builtin))
            }
            // Local and subscription targets have no marginal per-token cost,
            // whatever the vendor's list price is.
            let pricing: Pricing? = (kind.isLocal || kind.isSubscription) ? .free : live.pricing
            return (capabilities, pricing, bundled?.quality ?? qualityHeuristic(for: live))
        }

        guard let e = bundled else {
            // Unknown model: assume plain streaming chat. Tools are deliberately
            // NOT assumed — claiming a capability we lack causes hard failures,
            // while omitting one only costs us a routing option the user can
            // re-enable with a capability override.
            let caps = ModelCapabilities(flags: [.text, .streaming],
                                         contextWindow: kind.isLocal ? 8_192 : nil,
                                         source: .unknown)
            return (caps, kind.isLocal || kind.isSubscription ? .free : nil, kind.isLocal ? 55 : 60)
        }
        let caps = ModelCapabilities(flags: e.flags, contextWindow: e.context,
                                     maxOutputTokens: e.maxOutput, source: .builtin)
        // Local and subscription targets have no marginal per-token cost.
        let pricing: Pricing? = (kind.isLocal || kind.isSubscription) ? .free : e.pricing
        return (caps, pricing, e.quality)
    }

    /// A quality score for a model the bundled table has never heard of.
    ///
    /// Derived from what the live index states rather than invented: a bigger
    /// context, tool use and reasoning all indicate a more capable model. It is
    /// only a starting point — the score is the one number a user is expected to
    /// tune themselves.
    static func qualityHeuristic(for entry: RemoteModelCatalog.Entry) -> Double {
        var score = 60.0
        if let window = entry.contextWindow {
            if window >= 500_000 { score += 12 }
            else if window >= 180_000 { score += 8 }
            else if window >= 100_000 { score += 4 }
        }
        if entry.toolCall { score += 6 }
        if entry.reasoning { score += 8 }
        if entry.inputModalities.contains("image") { score += 4 }
        let name = (entry.id + " " + (entry.family ?? "")).lowercased()
        if name.contains("mini") || name.contains("lite") || name.contains("small") { score -= 12 }
        if name.contains("nano") || name.contains("tiny") { score -= 18 }
        if name.contains("opus") || name.contains("pro") || name.contains("max") { score += 6 }
        return Swift.min(98, Swift.max(35, score))
    }

    /// Models a provider kind is known to offer, used when discovery is not
    /// available (subscription backends do not expose a /models endpoint).
    public static func presetModels(for kind: ProviderKind) -> [String] {
        switch kind {
        case .claudeCodeCLI:
            // The CLI resolves these aliases to the newest model in each tier.
            return ["opus", "sonnet", "haiku"]
        case .anthropicSubscription, .anthropic:
            // Derived from the live index, so a model released since this file
            // was written is offered on the day it ships. The hand-written ids
            // below are only what is left when nothing live is available — a
            // stale list here quietly caps an account at last year's models.
            let live = ["opus", "sonnet", "haiku"]
                .compactMap { RemoteModelCatalog.shared.newestID(containing: $0, kind: kind) }
            if !live.isEmpty { return live }
            return ["claude-opus-4-5-20251101", "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001"]
        case .chatgptSubscription:
            // Discovered from the Codex CLI's own cached catalog instead — a
            // hardcoded list here went stale and hid the current models.
            return []
        case .geminiSubscription:
            return ["gemini-3-pro-preview", "gemini-2.5-flash"]
        case .qwenSubscription:
            return ["qwen3-coder-plus", "qwen3-max"]
        case .bedrock:
            return ["anthropic.claude-sonnet-4-5-20250929-v1:0", "anthropic.claude-haiku-4-5-20251001-v1:0"]
        case .azureOpenAI:
            return []
        default:
            return []
        }
    }
}
