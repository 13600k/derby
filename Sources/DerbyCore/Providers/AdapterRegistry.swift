import Foundation

/// Maps a provider kind to the adapter that speaks its protocol. This is the
/// only lookup table of its kind in Derby: adding a provider means adding an
/// entry here (or, for OpenAI-compatible services, a `ProviderKind` case).
public struct AdapterRegistry: Sendable {
    private let adapters: [AdapterFamily: any ProviderAdapter]

    public init(adapters: [AdapterFamily: any ProviderAdapter]? = nil) {
        self.adapters = adapters ?? [
            .openai: OpenAIAdapter(),
            .anthropic: AnthropicAdapter(oauth: false),
            .anthropicOAuth: AnthropicAdapter(oauth: true),
            .google: GoogleAdapter(),
            .chatgptCodex: ChatGPTCodexAdapter(),
            .bedrock: BedrockAdapter(),
        ]
    }

    public static let `default` = AdapterRegistry()

    public func adapter(for family: AdapterFamily) -> any ProviderAdapter {
        adapters[family] ?? OpenAIAdapter()
    }
    public func adapter(for kind: ProviderKind) -> any ProviderAdapter {
        adapter(for: kind.adapterFamily)
    }
    /// Returns a registry with one family replaced — used by tests.
    public func overriding(_ family: AdapterFamily, with adapter: any ProviderAdapter) -> AdapterRegistry {
        var copy = adapters
        copy[family] = adapter
        return AdapterRegistry(adapters: copy)
    }
}
