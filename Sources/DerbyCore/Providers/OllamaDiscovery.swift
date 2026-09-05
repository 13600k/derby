import Foundation

/// Reads Ollama's native `/api/tags`, which reports far more than its
/// OpenAI-compatible `/v1/models` shim.
///
/// The compatible endpoint returns only an id, so every discovered Ollama model
/// arrived with an unknown context window and no stated modalities. `/api/tags`
/// gives the real context length, the model's own capability list, parameter
/// size, quantization and family — in a single request.
public enum OllamaDiscovery {

    /// Ollama's capability vocabulary, mapped onto Derby's.
    static func flags(from capabilities: [String]) -> CapabilityFlags {
        var flags: CapabilityFlags = [.text, .streaming]
        for capability in capabilities {
            switch capability {
            case "vision": flags.insert(.vision)
            case "tools": flags.insert(.tools)
            case "thinking": flags.insert(.reasoning)
            case "embedding":
                flags.insert(.embeddings)
                // An embedding model does not complete text.
                flags.remove(.text)
                flags.remove(.streaming)
            case "completion", "insert": break
            default: break
            }
        }
        // Ollama's OpenAI layer accepts a JSON schema as the response format
        // for any completion model.
        if flags.contains(.text) { flags.insert(.jsonMode); flags.insert(.jsonSchema) }
        return flags
    }

    /// Base URL of the native API, derived from the configured OpenAI-compatible
    /// base (`http://host:11434/v1` → `http://host:11434`).
    static func nativeBase(from baseURL: String) -> String {
        var base = baseURL.trimmedTrailingSlash
        if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
        return base.trimmedTrailingSlash
    }

    public static func listModels(baseURL: String, transport: any HTTPTransport,
                                  timeout: Double, allowInsecureTLS: Bool,
                                  headers: [String: String] = [:]) async throws -> [DiscoveredModel] {
        guard let url = URL(string: nativeBase(from: baseURL) + "/api/tags") else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid Ollama base URL: \(baseURL)")
        }
        let response = try await transport.send(
            OutboundRequest(url: url, method: "GET", headers: headers,
                            timeout: timeout, allowInsecureTLS: allowInsecureTLS))
        guard (200..<300).contains(response.status), let json = response.bodyJSON else {
            throw DerbyError(kind: .providerDown,
                             message: "Ollama did not return a model list (HTTP \(response.status)).",
                             providerStatus: response.status)
        }
        return (json["models"]?.arrayValue ?? []).compactMap { parse($0) }
    }

    static func parse(_ item: JSONValue) -> DiscoveredModel? {
        guard let id = item["model"]?.stringValue ?? item["name"]?.stringValue else { return nil }
        let details = item["details"] ?? .null
        let reported = (item["capabilities"]?.arrayValue ?? []).compactMap { $0.stringValue }

        var capabilities = ModelCapabilities(flags: flags(from: reported), source: .discovered)
        capabilities.contextWindow = details["context_length"]?.intValue
        if capabilities.flags.contains(.embeddings) {
            capabilities.embeddingDimensions = details["embedding_length"]?.intValue
        }

        var profile = ModelProfile(
            family: details["family"]?.stringValue,
            parameterSize: details["parameter_size"]?.stringValue,
            quantization: details["quantization_level"]?.stringValue,
            format: details["format"]?.stringValue,
            diskSizeBytes: item["size"]?.intValue,
            ownedBy: "local")
        if let stamp = item["modified_at"]?.stringValue {
            profile.modifiedAt = ISO8601DateFormatter.withFractionalSeconds.date(from: stamp)
                ?? ISO8601DateFormatter().date(from: stamp)
        }

        return DiscoveredModel(id: id,
                               displayName: nil,
                               capabilities: capabilities,
                               profile: profile.isEmpty ? nil : profile,
                               // Local inference has no per-token cost.
                               pricing: .free)
    }
}
