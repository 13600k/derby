import Foundation

public enum CanonicalRole: String, Codable, Sendable, Hashable {
    case system, developer, user, assistant, tool
}

public struct CanonicalImage: Codable, Sendable, Hashable {
    /// Remote URL, when the client supplied one.
    public var url: String?
    /// Base64 payload (without data: prefix) when the client inlined the image.
    public var base64: String?
    public var mimeType: String
    public var detail: String?

    public init(url: String? = nil, base64: String? = nil, mimeType: String = "image/png", detail: String? = nil) {
        self.url = url; self.base64 = base64; self.mimeType = mimeType; self.detail = detail
    }

    /// Parses an OpenAI-style `image_url` value, which may be a data URI.
    public static func fromImageURLString(_ s: String, detail: String?) -> CanonicalImage {
        if s.hasPrefix("data:") {
            // data:image/png;base64,AAAA
            let afterScheme = s.dropFirst("data:".count)
            if let comma = afterScheme.firstIndex(of: ",") {
                let meta = String(afterScheme[afterScheme.startIndex..<comma])
                let payload = String(afterScheme[afterScheme.index(after: comma)...])
                let mime = meta.split(separator: ";").first.map(String.init) ?? "image/png"
                return CanonicalImage(base64: payload, mimeType: mime, detail: detail)
            }
        }
        return CanonicalImage(url: s, mimeType: "image/png", detail: detail)
    }

    public var asDataURI: String {
        if let b = base64 { return "data:\(mimeType);base64,\(b)" }
        return url ?? ""
    }
}

public struct CanonicalAudio: Codable, Sendable, Hashable {
    public var base64: String
    public var format: String   // "wav", "mp3", ...
    public init(base64: String, format: String) { self.base64 = base64; self.format = format }
}

public enum CanonicalContent: Codable, Sendable, Hashable {
    case text(String)
    case image(CanonicalImage)
    case audio(CanonicalAudio)
    case refusal(String)

    public var textValue: String? { if case .text(let t) = self { return t }; return nil }
    public var isImage: Bool { if case .image = self { return true }; return false }
    public var isAudio: Bool { if case .audio = self { return true }; return false }

    private enum CodingKeys: String, CodingKey { case type, text, image, audio }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "image": self = .image(try c.decode(CanonicalImage.self, forKey: .image))
        case "audio": self = .audio(try c.decode(CanonicalAudio.self, forKey: .audio))
        default: self = .refusal(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .image(let i): try c.encode("image", forKey: .type); try c.encode(i, forKey: .image)
        case .audio(let a): try c.encode("audio", forKey: .type); try c.encode(a, forKey: .audio)
        case .refusal(let r): try c.encode("refusal", forKey: .type); try c.encode(r, forKey: .text)
        }
    }
}

public struct CanonicalToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Raw JSON string of arguments (kept as a string because providers stream it that way).
    public var argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
    public var argumentsValue: JSONValue { JSONValue.parse(argumentsJSON) ?? .object([:]) }
}

public struct CanonicalMessage: Codable, Sendable, Hashable {
    public var role: CanonicalRole
    public var content: [CanonicalContent]
    public var name: String?
    public var toolCalls: [CanonicalToolCall]
    /// Set when `role == .tool`, identifying which call this responds to.
    public var toolCallID: String?
    /// Assistant reasoning/thinking text, when a provider exposes it.
    public var reasoning: String?

    public init(role: CanonicalRole,
                content: [CanonicalContent] = [],
                name: String? = nil,
                toolCalls: [CanonicalToolCall] = [],
                toolCallID: String? = nil,
                reasoning: String? = nil) {
        self.role = role; self.content = content; self.name = name
        self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.reasoning = reasoning
    }

    public static func user(_ text: String) -> CanonicalMessage { .init(role: .user, content: [.text(text)]) }
    public static func system(_ text: String) -> CanonicalMessage { .init(role: .system, content: [.text(text)]) }
    public static func assistant(_ text: String) -> CanonicalMessage { .init(role: .assistant, content: [.text(text)]) }

    public var joinedText: String {
        content.compactMap { $0.textValue }.joined()
    }
    public var hasImages: Bool { content.contains { $0.isImage } }
    public var hasAudio: Bool { content.contains { $0.isAudio } }
}

public struct CanonicalTool: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    /// JSON Schema object describing the parameters.
    public var parameters: JSONValue
    public var strict: Bool?
    public init(name: String, description: String? = nil, parameters: JSONValue = .object(["type": .string("object")]), strict: Bool? = nil) {
        self.name = name; self.description = description; self.parameters = parameters; self.strict = strict
    }
}

public enum CanonicalToolChoice: Codable, Sendable, Hashable {
    case auto
    case none
    case required
    case function(String)

    private enum CodingKeys: String, CodingKey { case kind, name }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none": self = .none
        case "required": self = .required
        case "function": self = .function(try c.decode(String.self, forKey: .name))
        default: self = .auto
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto: try c.encode("auto", forKey: .kind)
        case .none: try c.encode("none", forKey: .kind)
        case .required: try c.encode("required", forKey: .kind)
        case .function(let n): try c.encode("function", forKey: .kind); try c.encode(n, forKey: .name)
        }
    }
}

public enum CanonicalResponseFormat: Codable, Sendable, Hashable {
    case text
    case jsonObject
    case jsonSchema(name: String, schema: JSONValue, strict: Bool)

    private enum CodingKeys: String, CodingKey { case kind, name, schema, strict }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "json_object": self = .jsonObject
        case "json_schema":
            self = .jsonSchema(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "response",
                               schema: try c.decode(JSONValue.self, forKey: .schema),
                               strict: try c.decodeIfPresent(Bool.self, forKey: .strict) ?? false)
        default: self = .text
        }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        switch self {
        case .text: try c.encode("text", forKey: .kind)
        case .jsonObject: try c.encode("json_object", forKey: .kind)
        case .jsonSchema(let n, let s, let st):
            try c.encode("json_schema", forKey: .kind); try c.encode(n, forKey: .name)
            try c.encode(s, forKey: .schema); try c.encode(st, forKey: .strict)
        }
    }
}

/// Reasoning effort, weakest to strongest.
///
/// Providers have grown past the original four levels — the Codex catalog now
/// lists `xhigh`, `max` and `ultra` — so the scale is open-ended here and each
/// adapter maps it down to what its own API accepts.
public enum ReasoningEffort: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case minimal, low, medium, high, xhigh, max, ultra

    private var rank: Int {
        switch self {
        case .minimal: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .xhigh: return 4
        case .max: return 5
        case .ultra: return 6
        }
    }
    public static func < (a: ReasoningEffort, b: ReasoningEffort) -> Bool { a.rank < b.rank }

    /// This level and every weaker one, strongest first.
    public static func descendingFrom(_ effort: ReasoningEffort) -> [ReasoningEffort] {
        allCases.filter { $0 <= effort }.sorted(by: >)
    }

    /// The four levels the OpenAI REST API accepts. Anything stronger maps to
    /// `high` rather than being sent verbatim and rejected.
    public var standardOpenAIValue: String {
        switch self {
        case .minimal, .low, .medium, .high: return rawValue
        case .xhigh, .max, .ultra: return "high"
        }
    }

    /// A thinking-token budget for APIs that take one instead of a level.
    public var thinkingBudget: Int {
        switch self {
        case .minimal: return 1024
        case .low: return 2048
        case .medium: return 8192
        case .high: return 16384
        case .xhigh: return 24576
        case .max: return 32768
        case .ultra: return 49152
        }
    }

    public var displayName: String {
        switch self {
        case .xhigh: return "Extra high"
        default: return rawValue.capitalized
        }
    }
}

public struct ReasoningControls: Codable, Sendable, Hashable {
    public var effort: ReasoningEffort?
    public var maxTokens: Int?
    public var include: Bool
    public init(effort: ReasoningEffort? = nil, maxTokens: Int? = nil, include: Bool = false) {
        self.effort = effort; self.maxTokens = maxTokens; self.include = include
    }
}

/// The shape of the client-facing API the request arrived on. Derby answers in
/// the same dialect it was asked in.
public enum APIDialect: String, Codable, Sendable {
    case chatCompletions = "chat.completions"
    case responses = "responses"
    case embeddings = "embeddings"
}

/// A provider-independent chat request. Everything downstream of the API layer
/// works with this type.
public struct CanonicalRequest: Codable, Sendable {
    /// The model string the client asked for; usually a Derby logical model name.
    public var requestedModel: String
    public var messages: [CanonicalMessage]
    public var tools: [CanonicalTool]
    public var toolChoice: CanonicalToolChoice?
    public var parallelToolCalls: Bool?
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var stop: [String]
    public var stream: Bool
    public var responseFormat: CanonicalResponseFormat?
    public var reasoning: ReasoningControls?
    public var seed: Int?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var n: Int?
    public var user: String?
    public var dialect: APIDialect
    /// Free-form passthrough, keyed by provider family (e.g. "anthropic"), merged
    /// into the outbound provider payload by the adapter.
    public var providerExtensions: [String: JSONValue]
    /// Anything the client sent that Derby did not model, retained for debugging.
    public var unmappedFields: [String: JSONValue]

    public init(requestedModel: String,
                messages: [CanonicalMessage] = [],
                tools: [CanonicalTool] = [],
                toolChoice: CanonicalToolChoice? = nil,
                parallelToolCalls: Bool? = nil,
                temperature: Double? = nil,
                topP: Double? = nil,
                maxOutputTokens: Int? = nil,
                stop: [String] = [],
                stream: Bool = false,
                responseFormat: CanonicalResponseFormat? = nil,
                reasoning: ReasoningControls? = nil,
                seed: Int? = nil,
                frequencyPenalty: Double? = nil,
                presencePenalty: Double? = nil,
                n: Int? = nil,
                user: String? = nil,
                dialect: APIDialect = .chatCompletions,
                providerExtensions: [String: JSONValue] = [:],
                unmappedFields: [String: JSONValue] = [:]) {
        self.requestedModel = requestedModel
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.stop = stop
        self.stream = stream
        self.responseFormat = responseFormat
        self.reasoning = reasoning
        self.seed = seed
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.n = n
        self.user = user
        self.dialect = dialect
        self.providerExtensions = providerExtensions
        self.unmappedFields = unmappedFields
    }

    // MARK: - Derived properties used by routing

    public var hasImages: Bool { messages.contains { $0.hasImages } }
    public var hasAudio: Bool { messages.contains { $0.hasAudio } }
    public var usesTools: Bool { !tools.isEmpty }

    /// Rough token estimate for the prompt. Deliberately cheap: routing only
    /// needs an order of magnitude to filter out too-small context windows.
    public var estimatedPromptTokens: Int {
        var chars = 0
        var images = 0
        for m in messages {
            chars += m.role.rawValue.count + 4
            for c in m.content {
                switch c {
                case .text(let t): chars += t.count
                case .refusal(let t): chars += t.count
                case .image(let img):
                    images += 1
                    // base64 payloads are large but do not map 1:1 to tokens
                    if let b = img.base64 { chars += min(b.count / 40, 4000) }
                case .audio(let a): chars += min(a.base64.count / 40, 4000)
                }
            }
            for tc in m.toolCalls { chars += tc.name.count + tc.argumentsJSON.count }
        }
        for t in tools { chars += t.name.count + (t.description?.count ?? 0) + t.parameters.compactJSONString.count }
        return chars / 4 + images * 800 + 16
    }

    /// The capability set this specific request needs.
    public var capabilityRequirements: CapabilityRequirements {
        var flags: CapabilityFlags = [.text]
        if hasImages { flags.insert(.vision) }
        if hasAudio { flags.insert(.audioInput) }
        if usesTools { flags.insert(.tools) }
        if parallelToolCalls == true { flags.insert(.parallelTools) }
        if stream { flags.insert(.streaming) }
        if let rf = responseFormat {
            switch rf {
            case .text: break
            case .jsonObject: flags.insert(.jsonMode)
            case .jsonSchema: flags.insert(.jsonSchema)
            }
        }
        if let r = reasoning, r.effort != nil || r.maxTokens != nil { flags.insert(.reasoning) }
        return CapabilityRequirements(required: flags,
                                      minContextTokens: estimatedPromptTokens + (maxOutputTokens ?? 0),
                                      minOutputTokens: maxOutputTokens)
    }
}

/// A provider-independent embeddings request.
public struct CanonicalEmbeddingRequest: Codable, Sendable {
    public var requestedModel: String
    public var inputs: [String]
    public var dimensions: Int?
    public var encodingFormat: String?
    public var user: String?
    public init(requestedModel: String, inputs: [String], dimensions: Int? = nil,
                encodingFormat: String? = nil, user: String? = nil) {
        self.requestedModel = requestedModel; self.inputs = inputs
        self.dimensions = dimensions; self.encodingFormat = encodingFormat; self.user = user
    }
    public var capabilityRequirements: CapabilityRequirements {
        CapabilityRequirements(required: [.embeddings])
    }
    public var estimatedPromptTokens: Int { inputs.reduce(0) { $0 + $1.count / 4 } + 8 }
}
