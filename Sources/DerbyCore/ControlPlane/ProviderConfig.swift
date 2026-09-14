import Foundation

/// Which wire protocol an account speaks. This is the *only* place provider
/// identity is expressed; everything else reads the computed properties below.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    // First-party metered APIs
    case openai
    case azureOpenAI = "azure_openai"
    case anthropic
    case google
    case bedrock
    // OpenAI-compatible aggregators / metered APIs
    case openrouter, together, fireworks, groq, mistral, deepseek, xai
    case qwen                       // Alibaba DashScope compatible-mode
    // Subscription-backed consumer accounts
    /// Runs the `claude` CLI, which is unambiguously a first-party client and
    /// therefore draws on the subscription's plan limits. The direct-API sibling
    /// below presents the same identity over HTTP, but which lane Anthropic puts
    /// that in is account-dependent — see `ClaudeCodeIdentity`.
    case claudeCodeCLI = "claude_code_cli"
    case anthropicSubscription = "anthropic_subscription"
    case chatgptSubscription = "chatgpt_subscription"
    case geminiSubscription = "gemini_subscription"
    case qwenSubscription = "qwen_subscription"
    // Local servers (all OpenAI-compatible, but worth first-class UX)
    case ollama, lmStudio = "lm_studio", llamaCpp = "llama_cpp", vllm, sglang, localai
    // Anything else the user points us at
    case openAICompatible = "openai_compatible"

    /// The adapter family that knows how to talk to this kind.
    public var adapterFamily: AdapterFamily {
        switch self {
        case .anthropic: return .anthropic
        case .claudeCodeCLI: return .claudeCLI
        case .anthropicSubscription: return .anthropicOAuth
        case .google, .geminiSubscription: return .google
        case .chatgptSubscription: return .chatgptCodex
        case .bedrock: return .bedrock
        default: return .openai
        }
    }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .azureOpenAI: return "Azure OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        case .bedrock: return "AWS Bedrock"
        case .openrouter: return "OpenRouter"
        case .together: return "Together AI"
        case .fireworks: return "Fireworks AI"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .xai: return "xAI"
        case .qwen: return "Qwen (DashScope)"
        case .claudeCodeCLI: return "Claude Code (plan limits)"
        case .anthropicSubscription: return "Claude subscription (direct API)"
        case .chatgptSubscription: return "ChatGPT subscription"
        case .geminiSubscription: return "Gemini subscription"
        case .qwenSubscription: return "Qwen subscription"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .llamaCpp: return "llama.cpp"
        case .vllm: return "vLLM"
        case .sglang: return "SGLang"
        case .localai: return "LocalAI"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        }
    }

    public var defaultBaseURL: String? {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic, .anthropicSubscription: return "https://api.anthropic.com/v1"
        case .claudeCodeCLI: return nil          // spawns a CLI, not an endpoint
        case .google, .geminiSubscription: return "https://generativelanguage.googleapis.com/v1beta"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .together: return "https://api.together.xyz/v1"
        case .fireworks: return "https://api.fireworks.ai/inference/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .xai: return "https://api.x.ai/v1"
        case .qwen: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .chatgptSubscription: return "https://chatgpt.com/backend-api/codex"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        case .llamaCpp: return "http://127.0.0.1:8080/v1"
        case .vllm: return "http://127.0.0.1:8000/v1"
        case .sglang: return "http://127.0.0.1:30000/v1"
        case .localai: return "http://127.0.0.1:8080/v1"
        case .azureOpenAI, .bedrock, .openAICompatible, .qwenSubscription: return nil
        }
    }

    /// Local targets are preferred by `local_first` and treated as zero marginal cost.
    public var isLocal: Bool {
        switch self {
        case .ollama, .lmStudio, .llamaCpp, .vllm, .sglang, .localai: return true
        default: return false
        }
    }

    /// Subscription-backed accounts are flat-rate: they have a quota, not a bill.
    public var isSubscription: Bool {
        switch self {
        case .claudeCodeCLI, .anthropicSubscription, .chatgptSubscription,
             .geminiSubscription, .qwenSubscription: return true
        default: return false
        }
    }

    /// Kinds whose credentials come from an already-authenticated local CLI.
    public var cliCredentialSource: CLICredentialSource? {
        switch self {
        case .claudeCodeCLI, .anthropicSubscription: return .claudeCode
        case .chatgptSubscription: return .codexCLI
        case .geminiSubscription: return .geminiCLI
        case .qwenSubscription: return .qwenCLI
        default: return nil
        }
    }

    public var supportsModelDiscovery: Bool {
        switch self {
        case .azureOpenAI: return false      // deployments are named by the user
        case .claudeCodeCLI: return true
        default: return true
        }
    }

    /// True when the provider's model ids are tier aliases it resolves itself —
    /// the `claude` CLI takes `opus`/`sonnet`/`haiku` and runs the newest model
    /// in that tier. Metadata for the alias therefore has to mean the newest
    /// model's metadata, or every one of them reads as an unknown model with no
    /// context window and no capabilities.
    public var resolvesTierAliases: Bool {
        switch self {
        case .claudeCodeCLI: return true
        default: return false
        }
    }

    /// True when the provider publishes the definitive list of models this
    /// account may use, so discovery should *replace* the configured set rather
    /// than only adding to it. Otherwise a model that has been retired lingers
    /// forever and fails whenever it is routed to.
    public var hasAuthoritativeCatalog: Bool { isSubscription }

    /// Whether this kind needs an API key, and how strictly.
    ///
    /// Declared here rather than derived from overlapping conditions at each call
    /// site — that is what produced two API-key fields on the same form.
    public var apiKeyRequirement: APIKeyRequirement {
        // Credentials come from somewhere else entirely.
        if cliCredentialSource != nil { return .notApplicable }
        switch self {
        case .bedrock:
            return .notApplicable          // AWS access keys, not a bearer token
        case .ollama, .lmStudio, .llamaCpp, .vllm, .sglang, .localai:
            return .optional               // usually unauthenticated on loopback
        case .openAICompatible:
            return .optional               // depends entirely on the server
        default:
            return .required
        }
    }

    /// Grouping used by the "Add Provider" picker.
    public var category: ProviderCategory {
        if isSubscription { return .subscription }
        if isLocal { return .local }
        if self == .openAICompatible { return .custom }
        return .api
    }

    /// Assistant-message fields this server reads prior reasoning back from.
    /// Empty when it reads none — sending an unknown field to a strict endpoint
    /// fails the whole request, so only servers known to accept one get it.
    public var reasoningReplayFields: [String] {
        switch self {
        case .ollama: return ["reasoning"]
        case .vllm, .sglang: return ["reasoning", "reasoning_content"]
        case .llamaCpp, .lmStudio, .deepseek: return ["reasoning_content"]
        default: return []
        }
    }

    /// Whether the endpoint understands OpenAI's `developer` role. Protocols
    /// that hoist instructions do so themselves; other OpenAI-compatible servers
    /// only know `system`.
    public var acceptsDeveloperRole: Bool {
        adapterFamily != .openai || self == .openai || self == .azureOpenAI || self == .openrouter
    }
}

/// How a provider kind treats an API key.
public enum APIKeyRequirement: Sendable, Equatable {
    /// The provider rejects requests without one.
    case required
    /// Some deployments are protected, most are not.
    case optional
    /// Credentials come from a CLI login or AWS keys instead.
    case notApplicable

    public var isUsed: Bool { self != .notApplicable }
    public var prompt: String {
        switch self {
        case .required: return "Required by this provider"
        case .optional: return "Optional — leave empty if the endpoint needs no key"
        case .notApplicable: return ""
        }
    }
}

public enum ProviderCategory: String, Codable, Sendable, CaseIterable {
    case api, subscription, local, custom
    public var displayName: String {
        switch self {
        case .api: return "Pay-per-use APIs"
        case .subscription: return "Subscription accounts"
        case .local: return "Local model servers"
        case .custom: return "Custom endpoints"
        }
    }
}

public enum AdapterFamily: String, Codable, Sendable, CaseIterable {
    case openai, anthropic, anthropicOAuth = "anthropic_oauth", google
    case chatgptCodex = "chatgpt_codex", bedrock
    /// Spawns a local CLI rather than calling an HTTP endpoint.
    case claudeCLI = "claude_cli"

    /// Opaque reasoning this protocol can hand back to its provider.
    public var reasoningArtifactFormats: Set<ReasoningArtifact.Format> {
        switch self {
        case .anthropic, .anthropicOAuth, .bedrock: return [.anthropicThinking, .anthropicRedactedThinking]
        case .google: return [.geminiThoughtSignature]
        case .chatgptCodex: return [.openAIEncryptedReasoning]
        case .openai, .claudeCLI: return []
        }
    }

    /// Whether a tool result may contain images on this protocol.
    public var toolResultsAcceptImages: Bool {
        self == .anthropic || self == .anthropicOAuth || self == .bedrock
    }

    /// Anthropic and Bedrock accept tool call ids matching `^[a-zA-Z0-9_-]{1,64}$`
    /// only; an id minted by another provider can fall outside it.
    public var restrictsToolCallIDAlphabet: Bool {
        self == .anthropic || self == .anthropicOAuth || self == .bedrock
    }

    /// Whether the protocol takes its own opaque reasoning back from every
    /// earlier turn, not only from the tool loop still in progress.
    ///
    /// The Responses API does. Called with `store: false`, a conversation's
    /// reasoning items are how it continues from its earlier thinking, and the
    /// server decides what stays in context. Withholding a finished turn's items
    /// loses that thinking and can change the prompt from that point on, so
    /// none of what follows is served from the prompt cache. Anthropic and
    /// Gemini bind signed reasoning to the turn that produced it.
    public var replaysReasoningFromEarlierTurns: Bool {
        self == .chatgptCodex
    }

    /// Whether opaque reasoning issued to one account can be read back by a
    /// different account of the same family.
    ///
    /// Verified live on the Codex backend with two ChatGPT accounts: the second
    /// account replays the first account's `encrypted_content` and answers from
    /// what was inside it — a number the first account chose silently, recorded
    /// nowhere else, came back verbatim — while the same payload altered by 32
    /// characters is refused (`invalid_encrypted_content`). So the key belongs
    /// to the endpoint and the reasoning survives a change of account, which is
    /// what lets a subscription that ran out hand its tool loop to another one
    /// mid-thought. Anthropic signs per account and Gemini per turn, so theirs
    /// does not travel.
    public var reasoningCrossesAccounts: Bool {
        self == .chatgptCodex
    }
}

public enum CLICredentialSource: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude_code"
    case codexCLI = "codex_cli"
    case geminiCLI = "gemini_cli"
    case qwenCLI = "qwen_cli"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code CLI"
        case .codexCLI: return "Codex CLI"
        case .geminiCLI: return "Gemini CLI"
        case .qwenCLI: return "Qwen Code CLI"
        }
    }
    public var loginCommand: String {
        switch self {
        case .claudeCode: return "claude  (then /login)"
        case .codexCLI: return "codex login"
        case .geminiCLI: return "gemini  (then /auth)"
        case .qwenCLI: return "qwen  (then /auth)"
        }
    }
}

/// A reference to a secret held in the Keychain. The secret itself is never
/// written to the configuration file.
public struct SecretRef: Codable, Sendable, Hashable {
    public var account: String
    public init(account: String) { self.account = account }
    public static func new(_ prefix: String) -> SecretRef { SecretRef(account: "\(prefix).\(UUID().uuidString)") }
}

public enum AuthConfig: Codable, Sendable, Hashable {
    case none
    /// Sent as the provider's conventional API-key header (adapter decides which).
    case apiKey(SecretRef)
    /// Arbitrary header, e.g. `X-Custom-Token: <secret>`.
    case customHeader(name: String, ref: SecretRef, valuePrefix: String)
    /// Credentials read from a local, already-authenticated CLI.
    case cli(source: CLICredentialSource, allowRefresh: Bool)
    /// AWS SigV4 (Bedrock).
    case awsSigV4(accessKeyRef: SecretRef, secretKeyRef: SecretRef, sessionTokenRef: SecretRef?, region: String)

    public var secretRefs: [SecretRef] {
        switch self {
        case .none: return []
        case .apiKey(let r): return [r]
        case .customHeader(_, let r, _): return [r]
        case .cli: return []
        case .awsSigV4(let a, let s, let t, _): return [a, s] + (t.map { [$0] } ?? [])
        }
    }

    public var describesCLI: CLICredentialSource? {
        if case .cli(let s, _) = self { return s }
        return nil
    }

    public var displayName: String {
        switch self {
        case .none: return "No authentication"
        case .apiKey: return "API key"
        case .customHeader(let n, _, _): return "Header \(n)"
        case .cli(let s, _): return s.displayName
        case .awsSigV4(_, _, _, let r): return "AWS SigV4 (\(r))"
        }
    }
}

/// Provider-side limits Derby respects and uses for routing pressure.
public struct RateLimitConfig: Codable, Sendable, Hashable {
    public var requestsPerMinute: Int?
    public var tokensPerMinute: Int?
    public var maxConcurrentRequests: Int
    public var dailyRequestQuota: Int?
    public var monthlyCostBudgetUSD: Double?

    public init(requestsPerMinute: Int? = nil, tokensPerMinute: Int? = nil,
                maxConcurrentRequests: Int = 8, dailyRequestQuota: Int? = nil,
                monthlyCostBudgetUSD: Double? = nil) {
        self.requestsPerMinute = requestsPerMinute
        self.tokensPerMinute = tokensPerMinute
        self.maxConcurrentRequests = maxConcurrentRequests
        self.dailyRequestQuota = dailyRequestQuota
        self.monthlyCostBudgetUSD = monthlyCostBudgetUSD
    }
    public static let `default` = RateLimitConfig()
}

/// A concrete model offered by one account.
public struct PhysicalModel: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The identifier the provider expects on the wire.
    public var modelID: String
    public var displayName: String?
    public var enabled: Bool
    /// Capabilities Derby believes this model has, before user overrides.
    public var capabilities: ModelCapabilities
    public var capabilityOverrides: PartialCapabilities
    public var pricingOverride: Pricing?
    /// 0–100 subjective quality, used by weighted-score routing.
    public var qualityScore: Double
    public var discoveredAt: Date?
    /// Descriptive facts learned during discovery (size, quantization, family).
    public var profile: ModelProfile?

    public init(id: UUID = UUID(), modelID: String, displayName: String? = nil,
                enabled: Bool = true,
                capabilities: ModelCapabilities = .unknown,
                capabilityOverrides: PartialCapabilities = PartialCapabilities(),
                pricingOverride: Pricing? = nil,
                qualityScore: Double = 60,
                discoveredAt: Date? = nil,
                profile: ModelProfile? = nil) {
        self.id = id; self.modelID = modelID; self.displayName = displayName
        self.enabled = enabled; self.capabilities = capabilities
        self.capabilityOverrides = capabilityOverrides
        self.pricingOverride = pricingOverride
        self.qualityScore = qualityScore
        self.discoveredAt = discoveredAt
        self.profile = profile
    }

    public var effectiveCapabilities: ModelCapabilities { capabilities.overridden(by: capabilityOverrides) }
    public var label: String { displayName ?? modelID }
}

/// One configured account/endpoint. The same `ProviderKind` may appear many
/// times (OpenAI Personal, OpenAI Work, …); each is an independent routing
/// target with its own credentials, health and limits.
public struct ProviderAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var enabled: Bool
    /// Overrides `kind.defaultBaseURL`. Required for custom/Azure endpoints.
    public var baseURLOverride: String?
    public var auth: AuthConfig
    public var extraHeaders: [String: String]
    public var requestTimeoutSeconds: Double
    public var connectTimeoutSeconds: Double
    public var rateLimits: RateLimitConfig
    public var models: [PhysicalModel]
    public var notes: String
    public var createdAt: Date
    /// Azure deployments and API versions.
    public var apiVersion: String?
    /// Accept self-signed certificates (private inference servers).
    public var allowInsecureTLS: Bool
    /// Ranked preference used by the weighted-score strategy (0–100).
    public var preferenceScore: Double
    /// Absolute path to the CLI a command-line-backed provider should run.
    /// Nil means Derby locates it. Optional so older configurations decode.
    public var executablePathOverride: String?
    /// For CLI-linked accounts, the CLI state directory to read credentials from
    /// (`CODEX_HOME` / `CLAUDE_CONFIG_DIR`). Nil means the CLI's default home.
    /// This is what lets several accounts of the *same* service coexist.
    public var credentialHomeOverride: String?

    public init(id: UUID = UUID(), name: String, kind: ProviderKind, enabled: Bool = true,
                baseURLOverride: String? = nil, auth: AuthConfig = .none,
                extraHeaders: [String: String] = [:],
                requestTimeoutSeconds: Double = 120,
                connectTimeoutSeconds: Double = 10,
                rateLimits: RateLimitConfig = .default,
                models: [PhysicalModel] = [],
                notes: String = "",
                createdAt: Date = Date(),
                apiVersion: String? = nil,
                allowInsecureTLS: Bool = false,
                preferenceScore: Double = 50,
                credentialHomeOverride: String? = nil,
                executablePathOverride: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled
        self.baseURLOverride = baseURLOverride; self.auth = auth
        self.extraHeaders = extraHeaders
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.rateLimits = rateLimits; self.models = models; self.notes = notes
        self.createdAt = createdAt; self.apiVersion = apiVersion
        self.allowInsecureTLS = allowInsecureTLS
        self.preferenceScore = preferenceScore
        self.credentialHomeOverride = credentialHomeOverride
        self.executablePathOverride = executablePathOverride
    }

    /// Resolved credential home, or nil for the CLI default.
    public var credentialHomeURL: URL? {
        guard let path = credentialHomeOverride?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    public var baseURL: String {
        baseURLOverride?.trimmingCharacters(in: .whitespaces).trimmedTrailingSlash
            ?? kind.defaultBaseURL?.trimmedTrailingSlash
            ?? ""
    }
    public func model(id: UUID) -> PhysicalModel? { models.first { $0.id == id } }
    public func model(modelID: String) -> PhysicalModel? { models.first { $0.modelID == modelID } }
}

extension String {
    public var trimmedTrailingSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
