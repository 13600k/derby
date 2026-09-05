import Foundation

/// The runtime identity of the physical model behind a logical model: what
/// actually ran (or what would run next), described well enough that a client
/// which only ever asked for an alias can size its context window, decide which
/// features to use and account for its spend — without opening the app.
///
/// Built from a `ResolvedTarget`, which is where the bundled catalog,
/// discovery and the user's overrides have already been reconciled, so this is
/// the *effective* metadata rather than any one source's opinion.
public struct RuntimeModelInfo: Codable, Sendable, Hashable {
    /// The identifier the provider expects on the wire. This is what Derby also
    /// reports as `model` on the response, in place of the alias.
    public var modelID: String
    /// The user-facing name for the model, when the provider or user set one.
    public var displayName: String
    public var providerID: UUID?
    /// The name of the *account* that served the request ("OpenAI Work"), which
    /// is not the same thing as the provider kind.
    public var providerName: String
    /// `ProviderKind.rawValue` — stable, machine-readable.
    public var providerKind: String
    /// The human label for that kind ("Claude subscription").
    public var providerLabel: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var capabilities: CapabilityFlags
    /// Where the numbers above came from, so a client can tell measured
    /// metadata from Derby's conservative guess for an unknown model.
    public var capabilitySource: CapabilitySource
    public var pricing: Pricing?
    /// 0–100 subjective quality, as used by weighted-score routing.
    public var quality: Double
    public var isLocal: Bool
    public var isSubscription: Bool

    public init(modelID: String, displayName: String, providerID: UUID? = nil,
                providerName: String, providerKind: String, providerLabel: String,
                contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
                capabilities: CapabilityFlags = [], capabilitySource: CapabilitySource = .unknown,
                pricing: Pricing? = nil, quality: Double = 0,
                isLocal: Bool = false, isSubscription: Bool = false) {
        self.modelID = modelID
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.providerKind = providerKind
        self.providerLabel = providerLabel
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.capabilitySource = capabilitySource
        self.pricing = pricing
        self.quality = quality
        self.isLocal = isLocal
        self.isSubscription = isSubscription
    }

    public init(target: ResolvedTarget) {
        self.init(modelID: target.modelID,
                  displayName: target.model.label,
                  providerID: target.account.id,
                  providerName: target.providerName,
                  providerKind: target.account.kind.rawValue,
                  providerLabel: target.account.kind.displayName,
                  contextWindow: target.capabilities.contextWindow,
                  maxOutputTokens: target.capabilities.maxOutputTokens,
                  capabilities: target.capabilities.flags,
                  capabilitySource: target.capabilities.source,
                  pricing: target.pricing,
                  quality: target.quality,
                  isLocal: target.isLocal,
                  isSubscription: target.isSubscription)
    }

    /// "Alpha · m-a", the same label the app and the request inspector use.
    public var label: String { "\(providerName) · \(displayName)" }
}
