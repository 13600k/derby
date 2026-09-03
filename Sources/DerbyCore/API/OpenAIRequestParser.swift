import Foundation

/// Translates inbound OpenAI-dialect payloads into `CanonicalRequest`.
/// Unknown fields are preserved in `unmappedFields` rather than dropped, so the
/// request inspector can show exactly what a client sent.
public enum OpenAIRequestParser {

    private static let knownChatFields: Set<String> = [
        "model", "messages", "temperature", "top_p", "max_tokens", "max_completion_tokens",
        "n", "stream", "stream_options", "stop", "presence_penalty", "frequency_penalty",
        "user", "tools", "tool_choice", "parallel_tool_calls", "response_format", "seed",
        "reasoning_effort", "logprobs", "top_logprobs", "logit_bias", "metadata", "store",
        "service_tier", "modalities", "prediction", "derby",
    ]

    public static func parseChatCompletions(_ json: JSONValue) throws -> CanonicalRequest {
        guard let model = json["model"]?.stringValue, !model.isEmpty else {
            throw DerbyError.invalid("Missing required parameter: 'model'.")
        }
        guard let rawMessages = json["messages"]?.arrayValue else {
            throw DerbyError.invalid("Missing required parameter: 'messages'.")
        }
        var r = CanonicalRequest(requestedModel: model, dialect: .chatCompletions)
        r.messages = try rawMessages.map { try parseMessage($0) }
        r.temperature = json["temperature"]?.doubleValue
        r.topP = json["top_p"]?.doubleValue
        r.maxOutputTokens = json["max_completion_tokens"]?.intValue ?? json["max_tokens"]?.intValue
        r.n = json["n"]?.intValue
        r.stream = json["stream"]?.boolValue ?? false
        r.seed = json["seed"]?.intValue
        r.frequencyPenalty = json["frequency_penalty"]?.doubleValue
        r.presencePenalty = json["presence_penalty"]?.doubleValue
        r.user = json["user"]?.stringValue
        r.parallelToolCalls = json["parallel_tool_calls"]?.boolValue

        if let stop = json["stop"] {
            if let s = stop.stringValue { r.stop = [s] }
            else if let a = stop.arrayValue { r.stop = a.compactMap { $0.stringValue } }
        }
        if let tools = json["tools"]?.arrayValue {
            r.tools = tools.compactMap { t in
                // Accept both {"type":"function","function":{...}} and the flat form.
                let fn: JSONValue = t["function"] ?? t
                guard let name = fn["name"]?.stringValue else { return nil }
                return CanonicalTool(name: name,
                                     description: fn["description"]?.stringValue,
                                     parameters: fn["parameters"] ?? .object(["type": .string("object")]),
                                     strict: fn["strict"]?.boolValue)
            }
        }
        if let tc = json["tool_choice"] {
            if let s = tc.stringValue {
                switch s {
                case "none": r.toolChoice = CanonicalToolChoice.none
                case "required", "any": r.toolChoice = .required
                default: r.toolChoice = .auto
                }
            } else if let name = tc["function"]?["name"]?.stringValue ?? tc["name"]?.stringValue {
                r.toolChoice = .function(name)
            }
        }
        if let rf = json["response_format"] {
            switch rf["type"]?.stringValue {
            case "json_object": r.responseFormat = .jsonObject
            case "json_schema":
                let js = rf["json_schema"] ?? .object([:])
                r.responseFormat = .jsonSchema(name: js["name"]?.stringValue ?? "response",
                                               schema: js["schema"] ?? .object(["type": .string("object")]),
                                               strict: js["strict"]?.boolValue ?? false)
            case "text": r.responseFormat = .text
            default: break
            }
        }
        if let effort = json["reasoning_effort"]?.stringValue, let e = ReasoningEffort(rawValue: effort) {
            r.reasoning = ReasoningControls(effort: e)
        }
        // Derby-specific escape hatch: {"derby": {"provider_extensions": {...}}}
        if let derby = json["derby"]?.objectValue {
            if let ext = derby["provider_extensions"]?.objectValue {
                r.providerExtensions = ext
            }
        }
        r.unmappedFields = (json.objectValue ?? [:]).filter { !knownChatFields.contains($0.key) }
        return r
    }

    static func parseMessage(_ m: JSONValue) throws -> CanonicalMessage {
        let roleString = m["role"]?.stringValue ?? "user"
        let role = CanonicalRole(rawValue: roleString) ?? .user
        var msg = CanonicalMessage(role: role)
        msg.name = m["name"]?.stringValue
        msg.toolCallID = m["tool_call_id"]?.stringValue

        if let content = m["content"] {
            if let s = content.stringValue {
                if !s.isEmpty { msg.content = [.text(s)] }
            } else if let parts = content.arrayValue {
                msg.content = parts.compactMap { part -> CanonicalContent? in
                    switch part["type"]?.stringValue {
                    case "text", "input_text", "output_text":
                        return part["text"]?.stringValue.map { .text($0) }
                    case "image_url":
                        guard let iu = part["image_url"] else { return nil }
                        let urlString = iu.stringValue ?? iu["url"]?.stringValue ?? ""
                        guard !urlString.isEmpty else { return nil }
                        return .image(.fromImageURLString(urlString, detail: iu["detail"]?.stringValue))
                    case "input_image":
                        guard let u = part["image_url"]?.stringValue else { return nil }
                        return .image(.fromImageURLString(u, detail: part["detail"]?.stringValue))
                    case "input_audio":
                        guard let a = part["input_audio"],
                              let data = a["data"]?.stringValue else { return nil }
                        return .audio(CanonicalAudio(base64: data, format: a["format"]?.stringValue ?? "wav"))
                    case "refusal":
                        return part["refusal"]?.stringValue.map { .refusal($0) }
                    default:
                        return part["text"]?.stringValue.map { .text($0) }
                    }
                }
            }
        }
        if let calls = m["tool_calls"]?.arrayValue {
            msg.toolCalls = calls.map { c in
                CanonicalToolCall(id: c["id"]?.stringValue ?? IDGenerator.short(),
                                  name: c["function"]?["name"]?.stringValue ?? c["name"]?.stringValue ?? "",
                                  argumentsJSON: c["function"]?["arguments"]?.stringValue ?? "{}")
            }
        }
        return msg
    }

    // MARK: - Responses API

    public static func parseResponses(_ json: JSONValue) throws -> CanonicalRequest {
        guard let model = json["model"]?.stringValue, !model.isEmpty else {
            throw DerbyError.invalid("Missing required parameter: 'model'.")
        }
        var r = CanonicalRequest(requestedModel: model, dialect: .responses)
        var messages: [CanonicalMessage] = []

        if let instructions = json["instructions"]?.stringValue, !instructions.isEmpty {
            messages.append(.system(instructions))
        }
        if let input = json["input"] {
            if let s = input.stringValue {
                messages.append(.user(s))
            } else if let items = input.arrayValue {
                for item in items {
                    let type = item["type"]?.stringValue ?? "message"
                    switch type {
                    case "message":
                        messages.append(try parseResponsesMessage(item))
                    case "function_call":
                        messages.append(CanonicalMessage(
                            role: .assistant,
                            toolCalls: [CanonicalToolCall(id: item["call_id"]?.stringValue ?? IDGenerator.short(),
                                                          name: item["name"]?.stringValue ?? "",
                                                          argumentsJSON: item["arguments"]?.stringValue ?? "{}")]))
                    case "function_call_output":
                        messages.append(CanonicalMessage(role: .tool,
                                                         content: [.text(item["output"]?.stringValue ?? "")],
                                                         toolCallID: item["call_id"]?.stringValue))
                    default:
                        if let t = item["text"]?.stringValue { messages.append(.user(t)) }
                    }
                }
            }
        }
        r.messages = messages
        r.stream = json["stream"]?.boolValue ?? false
        r.temperature = json["temperature"]?.doubleValue
        r.topP = json["top_p"]?.doubleValue
        r.maxOutputTokens = json["max_output_tokens"]?.intValue
        r.user = json["user"]?.stringValue
        r.parallelToolCalls = json["parallel_tool_calls"]?.boolValue

        if let tools = json["tools"]?.arrayValue {
            r.tools = tools.compactMap { t in
                guard t["type"]?.stringValue == "function" || t["name"] != nil else { return nil }
                guard let name = t["name"]?.stringValue ?? t["function"]?["name"]?.stringValue else { return nil }
                return CanonicalTool(name: name,
                                     description: t["description"]?.stringValue,
                                     parameters: t["parameters"] ?? .object(["type": .string("object")]),
                                     strict: t["strict"]?.boolValue)
            }
        }
        if let tc = json["tool_choice"] {
            if let s = tc.stringValue {
                switch s {
                case "none": r.toolChoice = CanonicalToolChoice.none
                case "required": r.toolChoice = .required
                default: r.toolChoice = .auto
                }
            } else if let n = tc["name"]?.stringValue { r.toolChoice = .function(n) }
        }
        if let reasoning = json["reasoning"] {
            r.reasoning = ReasoningControls(
                effort: reasoning["effort"]?.stringValue.flatMap { ReasoningEffort(rawValue: $0) },
                include: reasoning["summary"] != nil)
        }
        if let format = json["text"]?["format"] {
            switch format["type"]?.stringValue {
            case "json_object": r.responseFormat = .jsonObject
            case "json_schema":
                r.responseFormat = .jsonSchema(name: format["name"]?.stringValue ?? "response",
                                               schema: format["schema"] ?? .object(["type": .string("object")]),
                                               strict: format["strict"]?.boolValue ?? false)
            default: break
            }
        }
        return r
    }

    private static func parseResponsesMessage(_ item: JSONValue) throws -> CanonicalMessage {
        let role = CanonicalRole(rawValue: item["role"]?.stringValue ?? "user") ?? .user
        var msg = CanonicalMessage(role: role)
        if let content = item["content"] {
            if let s = content.stringValue {
                msg.content = [.text(s)]
            } else if let parts = content.arrayValue {
                msg.content = parts.compactMap { p in
                    switch p["type"]?.stringValue {
                    case "input_text", "output_text", "text":
                        return p["text"]?.stringValue.map { .text($0) }
                    case "input_image":
                        guard let u = p["image_url"]?.stringValue ?? p["image_url"]?["url"]?.stringValue else { return nil }
                        return .image(.fromImageURLString(u, detail: p["detail"]?.stringValue))
                    case "refusal":
                        return p["refusal"]?.stringValue.map { .refusal($0) }
                    default:
                        return p["text"]?.stringValue.map { .text($0) }
                    }
                }
            }
        }
        return msg
    }

    // MARK: - Embeddings

    public static func parseEmbeddings(_ json: JSONValue) throws -> CanonicalEmbeddingRequest {
        guard let model = json["model"]?.stringValue, !model.isEmpty else {
            throw DerbyError.invalid("Missing required parameter: 'model'.")
        }
        guard let input = json["input"] else {
            throw DerbyError.invalid("Missing required parameter: 'input'.")
        }
        var inputs: [String] = []
        if let s = input.stringValue { inputs = [s] }
        else if let a = input.arrayValue {
            // Token-array inputs are not supported; strings only.
            inputs = a.compactMap { $0.stringValue }
            if inputs.isEmpty && !a.isEmpty {
                throw DerbyError.invalid("Derby supports string inputs for embeddings, not pre-tokenized arrays.")
            }
        }
        guard !inputs.isEmpty else { throw DerbyError.invalid("'input' must contain at least one string.") }
        return CanonicalEmbeddingRequest(requestedModel: model, inputs: inputs,
                                         dimensions: json["dimensions"]?.intValue,
                                         encodingFormat: json["encoding_format"]?.stringValue,
                                         user: json["user"]?.stringValue)
    }
}
