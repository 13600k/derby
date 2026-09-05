import Foundation
@testable import DerbyCore

/// A client only ever asks for an alias. These tests pin down what it can learn
/// about the physical model that actually served it.
func registerRuntimeMetadataTests() {

    func twoProviders() -> DerbyConfig {
        let alpha = Fixture.account("Alpha", kind: .openai,
                                    models: [Fixture.model("m-a", quality: 91, context: 200_000,
                                                           pricing: Pricing(inputPerMTok: 3, outputPerMTok: 15))])
        let beta = Fixture.account("Beta", kind: .ollama,
                                   models: [Fixture.model("m-b", quality: 55, context: 32_768)])
        return Fixture.config(accounts: [alpha, beta],
                              logicalModels: [Fixture.logical("coding", accounts: [alpha, beta])])
    }

    func executor(_ adapter: MockAdapter) -> Executor {
        Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                 transport: MockTransport(), secrets: InMemorySecretStore(),
                 credentials: CredentialCache(),
                 health: HealthRegistry(settings: HealthSettings(windowSize: 20, failureThreshold: 2,
                                                                 minimumSamples: 2, openDurationSeconds: 60)),
                 telemetry: NullTelemetrySink())
    }

    suite("Runtime metadata / resolution") {
        test("runtime info describes the effective model, not the catalog default") {
            var config = twoProviders()
            // A user override must win, the same way it does for routing.
            config.providers[0].models[0].capabilityOverrides =
                PartialCapabilities(flags: [.text, .streaming, .tools, .vision], contextWindow: 400_000)
            let snapshot = Fixture.snapshot(config)
            let target = try expectNotNil(snapshot.logicalModel(named: "coding")?.targets.first)
            let info = RuntimeModelInfo(target: target)

            try expectEqual(info.modelID, "m-a")
            try expectEqual(info.providerName, "Alpha")
            try expectEqual(info.providerKind, "openai")
            try expectEqual(info.providerLabel, "OpenAI")
            try expectEqual(info.contextWindow, 400_000, "the user's override is the runtime truth")
            try expect(info.capabilities.contains(.vision))
            try expectEqual(info.capabilitySource, .userOverride)
            try expectEqual(info.pricing?.inputPerMTok, 3)
            try expectEqual(info.isLocal, false)
        }

        test("a local target is reported as local and free") {
            let snapshot = Fixture.snapshot(twoProviders())
            let targets = try expectNotNil(snapshot.logicalModel(named: "coding")?.targets)
            let info = RuntimeModelInfo(target: try expectNotNil(targets.last))
            try expectEqual(info.providerKind, "ollama")
            try expectEqual(info.isLocal, true)
            try expectEqual(info.pricing?.isFlatRate, true)
        }
    }

    suite("Runtime metadata / metadata completion") {
        /// A provider's model list says which features a model has; it almost
        /// never says how big the window is. Derby used to choose between
        /// discovery and its catalog wholesale, which left every discovered
        /// model with no context window at all.
        func discovered(_ id: String, flags: CapabilityFlags) -> PhysicalModel {
            PhysicalModel(modelID: id, enabled: true,
                          capabilities: ModelCapabilities(flags: flags, contextWindow: nil,
                                                          maxOutputTokens: nil, source: .discovered))
        }

        test("a discovered model still gets a context window from the catalog") {
            let account = Fixture.account("ChatGPT subscription", kind: .chatgptSubscription,
                                          models: [discovered("gpt-5.6-terra",
                                                              flags: [.text, .tools, .reasoning, .streaming])])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("tester", accounts: [account])])
            let target = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "tester")?.targets.first)

            try expectEqual(target.capabilities.contextWindow, 400_000, "filled in from the catalog")
            try expectEqual(target.capabilities.maxOutputTokens, 128_000)
            // ...without inventing features discovery did not report.
            try expect(!target.capabilities.flags.contains(.vision))
            try expectEqual(target.capabilities.source, .discovered)
        }

        test("what the provider did report is never overwritten") {
            var model = discovered("gpt-5.6-terra", flags: [.text, .streaming])
            model.capabilities.contextWindow = 64_000
            let account = Fixture.account("ChatGPT subscription", kind: .chatgptSubscription, models: [model])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("tester", accounts: [account])])
            let target = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "tester")?.targets.first)
            try expectEqual(target.capabilities.contextWindow, 64_000)
        }

        test("a user override still beats both") {
            var model = discovered("gpt-5.6-terra", flags: [.text, .streaming])
            model.capabilityOverrides = PartialCapabilities(contextWindow: 12_345)
            let account = Fixture.account("ChatGPT subscription", kind: .chatgptSubscription, models: [model])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("tester", accounts: [account])])
            let target = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "tester")?.targets.first)
            try expectEqual(target.capabilities.contextWindow, 12_345)
            try expectEqual(target.capabilities.source, .userOverride)
        }

        test("an unknown model still takes the catalog wholesale") {
            var model = PhysicalModel(modelID: "claude-opus-4-5-20251101", enabled: true,
                                      capabilities: .unknown)
            model.capabilities.source = .unknown
            let account = Fixture.account("Claude", kind: .anthropic, models: [model])
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("smart", accounts: [account])])
            let target = try expectNotNil(Fixture.snapshot(config).logicalModel(named: "smart")?.targets.first)
            try expectEqual(target.capabilities.contextWindow, 200_000)
            try expect(target.capabilities.flags.contains(.vision), "the catalog's flags apply when nothing is known")
        }
    }

    suite("Runtime metadata / models list") {
        test("each alias advertises the model that would actually answer it") {
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(twoProviders()))
            let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })

            // The alias keeps its OpenAI-shaped identity...
            try expectEqual(coding["object"]?.stringValue, "model")
            try expectEqual(coding["owned_by"]?.stringValue, "derby")
            // ...but now says what it resolves to right now.
            let active = try expectNotNil(coding["derby"]?["active_model"])
            try expectEqual(active["id"]?.stringValue, "m-a")
            try expectEqual(active["provider"]?.stringValue, "Alpha")
            try expectEqual(active["provider_kind"]?.stringValue, "openai")
            try expectEqual(active["context_window"]?.intValue, 200_000)
            try expectEqual(active["max_output_tokens"]?.intValue, 8192)
            try expectEqual(active["pricing"]?["input_per_mtok_usd"]?.doubleValue, 3)
            try expect((active["capabilities"]?.arrayValue ?? []).contains(.string("tools")))

            // The most-acted-on numbers are also at the top level, where clients
            // look: the largest window reachable through the alias.
            try expectEqual(coding["context_window"]?.intValue, 200_000)
            try expectEqual(coding["max_output_tokens"]?.intValue, 8192)
            try expect(!(coding["derby"]?["routing_reason"]?.stringValue ?? "").isEmpty)
        }

        test("every configured target is listed with its own metadata and health") {
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(twoProviders()))
            let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })
            let targets = try expectNotNil(coding["derby"]?["targets"]?.arrayValue)
            try expectEqual(targets.count, 2)
            try expectEqual(coding["derby"]?["target_count"]?.intValue, 2)

            try expectEqual(targets[0]["id"]?.stringValue, "m-a")
            try expectEqual(targets[0]["rank"]?.intValue, 0)
            try expectEqual(targets[0]["active"]?.boolValue, true)
            try expectEqual(targets[0]["available"]?.boolValue, true)
            try expectEqual(targets[0]["health"]?.stringValue, "UNKNOWN")

            try expectEqual(targets[1]["id"]?.stringValue, "m-b")
            try expectEqual(targets[1]["context_window"]?.intValue, 32_768,
                            "a fallback's window differs from the active one and must be visible")
            try expectEqual(targets[1]["active"]?.boolValue, false)
        }

        test("the alias publishes both the reachable ceiling and the guaranteed floor") {
            // twoProviders(): a 200k primary and a 32k fallback.
            //
            // Top level is the ceiling: an oversized prompt is never truncated —
            // capability filtering routes it to a target that fits or refuses it —
            // so a client may safely use the full 200k, and the number does not
            // move as health or strategy change.
            //
            // `min_context_window` is the conservative counterpart: the size that
            // still fits every target, i.e. with failover fully intact.
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(twoProviders()))
            let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })
            try expectEqual(coding["context_window"]?.intValue, 200_000, "largest reachable window")
            try expectEqual(coding["derby"]?["min_context_window"]?.intValue, 32_768, "the floor across targets")
            // And the group's own capability summary agrees.
            try expectEqual(coding["derby"]?["max_context_window"]?.intValue, 200_000)
        }

        test("an unknown window suppresses the floor rather than guessing one") {
            var config = twoProviders()
            // A hosted model whose name the catalog cannot place: nothing to fall
            // back on, so the window stays genuinely unknown. (A *local* provider
            // would still assume a conservative 8k, which is a real floor.)
            config.providers[0].models[0].modelID = "some-unlisted-model"
            config.providers[0].models[0].capabilities = ModelCapabilities(flags: [.text, .streaming],
                                                                           contextWindow: nil,
                                                                           source: .discovered)
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(config))
            let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })
            try expect(coding["derby"]?["min_context_window"] == nil,
                       "an unknown window could be smaller than every known one")
        }

        test("a disabled target says so instead of being silently dropped") {
            var config = twoProviders()
            config.providers[0].models[0].enabled = false
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(config))
            let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })
            let targets = try expectNotNil(coding["derby"]?["targets"]?.arrayValue)
            try expectEqual(targets[0]["available"]?.boolValue, false)
            try expectContains(try expectNotNil(targets[0]["unavailable_reason"]?.stringValue), "turned off")
            // Routing has moved on, and the advertised metadata moves with it.
            try expectEqual(coding["derby"]?["active_model"]?["id"]?.stringValue, "m-b")
            try expectEqual(coding["context_window"]?.intValue, 32_768)
        }

        test("an alias with nothing eligible advertises no active model") {
            var config = twoProviders()
            config.providers[0].enabled = false
            config.providers[1].enabled = false
            let json = OpenAIResponseWriter.modelsList(Fixture.snapshot(config))
            let coding = try expectNotNil(json["data"]?.arrayValue?.first { $0["id"]?.stringValue == "coding" })
            try expect(coding["derby"]?["active_model"] == nil)
            try expect(coding["context_window"] == nil)
            try expectEqual(coding["derby"]?["target_count"]?.intValue, 0)
        }
    }

    suite("Runtime metadata / responses") {
        test("x_derby describes the model that answered, after a failover") {
            let adapter = MockAdapter()
            adapter.set("m-a", .fail(DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)))
            adapter.set("m-b", .succeed(text: "beta answered"))
            let config = twoProviders()
            let outcome = try await executor(adapter).execute(
                CanonicalRequest(requestedModel: "coding"),
                decision: try Fixture.decision(config, model: "coding"),
                meta: RequestMeta())

            let runtime = try expectNotNil(outcome.record.runtimeModel)
            try expectEqual(runtime.modelID, "m-b", "the runtime model is the one that ran, not the one ranked first")

            let meta = OpenAIResponseWriter.derbyMetadata(outcome.record)
            try expectEqual(meta["physical_model"]?.stringValue, "m-b")
            let model = try expectNotNil(meta["model"])
            try expectEqual(model["id"]?.stringValue, "m-b")
            try expectEqual(model["provider"]?.stringValue, "Beta")
            try expectEqual(model["context_window"]?.intValue, 32_768)
            try expectEqual(model["local"]?.boolValue, true)
            // The fixture states this target's capabilities, so they read as
            // provider-reported rather than as a guess from the bundled table.
            try expectEqual(model["metadata_source"]?.stringValue, "discovered")
        }

        test("a failed request carries no runtime model to misreport") {
            let adapter = MockAdapter()
            adapter.defaultBehaviour = .fail(DerbyError(kind: .providerDown, message: "down", providerStatus: 503))
            let sink = RecordingSink()
            let ex = Executor(registry: AdapterRegistry(adapters: [.openai: adapter]),
                              transport: MockTransport(), secrets: InMemorySecretStore(),
                              credentials: CredentialCache(),
                              health: HealthRegistry(settings: .default), telemetry: sink)
            _ = try? await ex.execute(CanonicalRequest(requestedModel: "coding"),
                                      decision: try Fixture.decision(twoProviders(), model: "coding"),
                                      meta: RequestMeta())
            let record = try expectNotNil(sink.last)
            try expect(record.runtimeModel == nil)
            try expect(OpenAIResponseWriter.derbyMetadata(record)["model"] == nil,
                       "no target ran, so there is nothing to describe")
        }

        test("derived token counts are flagged rather than passed off as measured") {
            var record = RequestRecord(logicalModel: "coding", finalModelID: "m-a")
            record.usage = .estimated(promptTokens: 100, completionText: "some text")
            let meta = OpenAIResponseWriter.derbyMetadata(record)
            try expectEqual(meta["usage_estimated"]?.boolValue, true)

            record.usage = CanonicalUsage(inputTokens: 100, outputTokens: 10)
            try expect(OpenAIResponseWriter.derbyMetadata(record)["usage_estimated"] == nil)
        }

        test("route metadata is available before a request finishes") {
            let snapshot = Fixture.snapshot(twoProviders())
            let target = try expectNotNil(snapshot.logicalModel(named: "coding")?.targets.first)
            let meta = OpenAIResponseWriter.routeMetadata(requestID: "req_1", logicalModel: "coding",
                                                          strategy: "priority", target: target,
                                                          attemptIndex: 0, routingReason: "first in order")
            try expectEqual(meta["logical_model"]?.stringValue, "coding")
            try expectEqual(meta["physical_model"]?.stringValue, "m-a")
            try expectEqual(meta["attempt"]?.stringValue, "attempt_1")
            try expectEqual(meta["model"]?["context_window"]?.intValue, 200_000)
            try expectEqual(meta["routing_reason"]?.stringValue, "first in order")
        }
    }
}
