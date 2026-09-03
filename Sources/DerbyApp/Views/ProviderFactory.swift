import Foundation
import DerbyCore

/// Builds provider accounts from templates and discovery results.
enum ProviderFactory {

    static func template(for kind: ProviderKind, name: String? = nil) -> ProviderAccount {
        var account = ProviderAccount(name: name ?? kind.displayName, kind: kind)
        account.baseURLOverride = kind.defaultBaseURL
        if let source = kind.cliCredentialSource {
            account.auth = .cli(source: source, allowRefresh: false)
        } else if kind.isLocal {
            account.auth = .none
        } else if kind == .bedrock {
            account.auth = .awsSigV4(accessKeyRef: .new("aws.access"),
                                     secretKeyRef: .new("aws.secret"),
                                     sessionTokenRef: nil, region: "us-east-1")
        } else {
            account.auth = .apiKey(.new("provider.key"))
        }
        if kind.isLocal { account.requestTimeoutSeconds = 600 }
        if kind.isSubscription { account.preferenceScore = 70 }
        // Seed the models a subscription backend is known to serve, since it
        // cannot be asked.
        for id in ModelCatalog.presetModels(for: kind) {
            account.models.append(makeModel(id: id, kind: kind))
        }
        return account
    }

    static func makeModel(id: String, kind: ProviderKind, discovered: DiscoveredModel? = nil) -> PhysicalModel {
        let catalog = ModelCatalog.metadata(for: id, kind: kind)
        var model = PhysicalModel(modelID: id,
                                  displayName: discovered?.displayName,
                                  capabilities: discovered?.capabilities ?? catalog.capabilities,
                                  qualityScore: catalog.quality,
                                  discoveredAt: discovered == nil ? nil : Date())
        if let p = catalog.pricing { model.pricingOverride = p }
        return model
    }

    @MainActor
    static func addSubscription(_ finding: LocalDiscovery.SubscriptionFinding, model: AppModel) async {
        let account = template(for: finding.kind)
        await model.mutate("Added \(finding.kind.displayName)") { $0.providers.append(account) }
        await model.scanForLocalServers()
    }

    @MainActor
    static func addLocalServer(_ finding: LocalDiscovery.Finding, model: AppModel) async {
        var built = template(for: finding.kind)
        built.baseURLOverride = finding.baseURL
        built.models = finding.models.map { makeModel(id: $0, kind: finding.kind) }
        let account = built
        let count = account.models.count
        await model.mutate("Imported \(finding.kind.displayName) with \(count) model\(count == 1 ? "" : "s")") {
            $0.providers.append(account)
        }
        await model.scanForLocalServers()
    }
}
