import Foundation

/// Every suite registers here. Keeping the list explicit means a new file is
/// never silently skipped.
func registerAllTests() {
    registerCanonicalTests()
    registerCapabilityTests()
    registerRoutingTests()
    registerStrategyTests()
    registerExecutionTests()
    registerReliabilityTests()
    registerProviderTests()
    registerAPIKeyTests()
    registerHTTPTests()
    registerPersistenceTests()
    registerCredentialTests()
    registerForwardCompatibilityTests()
    registerCodexCatalogTests()
    registerMultiAccountTests()
    registerModelMetadataTests()
    registerContractTests()
    registerRemoteCatalogTests()
    registerParameterSupportTests()
    registerClaudeCLITests()
    registerRuntimeMetadataTests()
    registerCompactionTests()
    registerEndToEndTests()
}
