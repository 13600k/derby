import Foundation

/// Every suite registers here. Keeping the list explicit means a new file is
/// never silently skipped.
func registerAllTests() {
    registerCanonicalTests()
    registerCapabilityTests()
    registerRoutingTests()
    registerStrategyTests()
    registerExecutionTests()
    registerTimeoutTests()
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
    registerBenchmarkTests()
    registerParameterSupportTests()
    registerClaudeCLITests()
    registerRuntimeMetadataTests()
    registerCompactionTests()
    registerHandoffTests()
    registerPromptCacheTests()
    registerContinuityTests()
    registerLoadTests()
    registerEndToEndTests()
    // Checks against this machine's real providers. Opt-in, because every other
    // suite must pass with no network at all: DERBY_LIVE=1 swift run DerbyTests Live
    if ProcessInfo.processInfo.environment["DERBY_LIVE"] == "1" { registerLiveTests() }
}
