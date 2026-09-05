import Foundation
@testable import DerbyCore

func registerPersistenceTests() {
    func tempURL(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    suite("Persistence / configuration") {
        test("a full configuration survives a save and reload") {
            let url = tempURL("config.json")
            let store = ConfigStore(url: url)
            let account = ProviderAccount(name: "OpenAI — Personal", kind: .openai,
                                          auth: .apiKey(SecretRef(account: "ref-1")),
                                          extraHeaders: ["x-team": "derby"],
                                          rateLimits: RateLimitConfig(requestsPerMinute: 60, maxConcurrentRequests: 4),
                                          models: [Fixture.model("gpt-test", quality: 88)],
                                          preferenceScore: 77)
            var lm = Fixture.logical("coding", accounts: [account], strategy: .weightedScore)
            lm.policy.scoreWeights = ScoreWeights(quality: 0.4, latency: 0.2, cost: 0.1, health: 0.2, quota: 0.1)
            lm.failover = FailoverConfig(enabled: true, maxAttempts: 3,
                                         dispositions: [.rateLimit: .returnToClient, .timeout: .failover])
            lm.hedging = HedgeConfig(enabled: true, delaySeconds: 0.7, maxParallel: 2)
            lm.budget = BudgetRules(maxCostPerRequestUSD: 0.25, dailyCostCapUSD: 5)
            lm.defaults = RequestDefaults(temperature: 0.2, systemPrompt: "House style", systemPromptMode: .replace)
            var config = Fixture.config(accounts: [account], logicalModels: [lm])
            config.gateway = GatewaySettings(port: 9999, requireAPIKey: true,
                                             localKeyRef: SecretRef(account: "gw"), autoStart: false)

            try store.save(config)
            let reloaded = ConfigStore(url: url).load()
            try expect(!reloaded.isFirstRun)
            let back = reloaded.config
            try expectEqual(back.gateway.port, 9999)
            try expectEqual(back.providers.count, 1)
            try expectEqual(back.providers[0].name, "OpenAI — Personal")
            try expectEqual(back.providers[0].extraHeaders["x-team"], "derby")
            try expectEqual(back.providers[0].rateLimits.requestsPerMinute, 60)
            try expectEqual(back.providers[0].models[0].qualityScore, 88)
            let backLM = try expectNotNil(back.logicalModel(named: "coding"))
            try expectEqual(backLM.policy.strategy, .weightedScore)
            try expectClose(backLM.policy.scoreWeights.quality, 0.4)
            try expectEqual(backLM.failover.dispositions[.rateLimit], .returnToClient)
            try expectEqual(backLM.hedging.enabled, true)
            try expectEqual(backLM.budget.maxCostPerRequestUSD, 0.25)
            try expectEqual(backLM.defaults.systemPromptMode, .replace)
            try expectEqual(backLM.targets.count, 1)
        }

        test("secrets are never written to the config file") {
            let url = tempURL("config.json")
            let account = ProviderAccount(name: "P", kind: .openai, auth: .apiKey(SecretRef(account: "ref-1")))
            try ConfigStore(url: url).save(DerbyConfig(providers: [account]))
            let text = try String(contentsOf: url, encoding: .utf8)
            try expectContains(text, "ref-1")
            try expect(!text.lowercased().contains("sk-"), "no key material may appear in config.json")
        }

        test("first run seeds five editable logical models with distinct strategies") {
            let url = tempURL("missing.json")
            let loaded = ConfigStore(url: url).load()
            try expect(loaded.isFirstRun)
            let names = loaded.config.logicalModels.map(\.name).sorted()
            try expectEqual(names, ["cheap", "coding", "fast", "local", "smart"])
            let strategies = Set(loaded.config.logicalModels.map { $0.policy.strategy })
            try expect(strategies.count >= 3, "the seeds should demonstrate several strategies")
            try expect(loaded.config.providers.isEmpty, "no provider credentials may be assumed")
        }

        test("a corrupt config is moved aside and Derby still starts") {
            let url = tempURL("config.json")
            try Data("{ this is not json".utf8).write(to: url)
            let loaded = ConfigStore(url: url).load()
            try expect(loaded.isFirstRun)
            try expect(!loaded.warnings.isEmpty)
            try expectContains(loaded.warnings[0], "could not be read")
        }

        test("unknown future fields do not break loading") {
            let url = tempURL("config.json")
            let json = """
            {"schemaVersion":1,"providers":[],"logicalModels":[],
             "somethingFromTheFuture":{"a":1},"gateway":{"port":1234,"bindAddress":"127.0.0.1",
             "requireAPIKey":false,"localKeyRef":{"account":"gw"},"autoStart":false,
             "allowRemoteAccess":false,"maxConcurrentRequests":8,"allowedOrigins":[]}}
            """
            try Data(json.utf8).write(to: url)
            let loaded = ConfigStore(url: url).load()
            try expect(!loaded.isFirstRun)
            try expectEqual(loaded.config.gateway.port, 1234)
        }

        test("a partially-written section falls back to defaults instead of failing") {
            let url = tempURL("config.json")
            try Data(#"{"schemaVersion":1,"gateway":"not an object"}"#.utf8).write(to: url)
            let loaded = ConfigStore(url: url).load()
            try expectEqual(loaded.config.gateway.port, GatewaySettings.default.port)
        }

        test("an existing loopback config drops the client key requirement") {
            var raw: [String: Any] = [
                "schemaVersion": 1,
                "gateway": ["port": 8787, "bindAddress": "127.0.0.1", "requireAPIKey": true,
                            "localKeyRef": ["account": "gw"], "autoStart": true,
                            "allowRemoteAccess": false, "maxConcurrentRequests": 64,
                            "allowedOrigins": []],
            ]
            let notes = ConfigMigrator.migrate(rawObject: &raw)
            try expectEqual(raw["schemaVersion"] as? Int, 2)
            try expectEqual((raw["gateway"] as? [String: Any])?["requireAPIKey"] as? Bool, false)
            try expect(notes.contains { $0.contains("no longer need") })
        }

        test("a config reachable off this Mac keeps its key requirement") {
            var raw: [String: Any] = [
                "schemaVersion": 1,
                "gateway": ["port": 8787, "bindAddress": "0.0.0.0", "requireAPIKey": true,
                            "localKeyRef": ["account": "gw"], "autoStart": true,
                            "allowRemoteAccess": true, "maxConcurrentRequests": 64,
                            "allowedOrigins": []],
            ]
            let notes = ConfigMigrator.migrate(rawObject: &raw)
            try expectEqual(raw["schemaVersion"] as? Int, 2)
            try expectEqual((raw["gateway"] as? [String: Any])?["requireAPIKey"] as? Bool, true,
                            "a LAN-reachable gateway must not be opened up by a migration")
            try expect(notes.contains { $0.contains("left on") })
        }

        test("a fresh install asks clients for nothing but the port") {
            let loaded = ConfigStore(url: tempURL("missing.json")).load()
            try expect(!loaded.config.gateway.requireAPIKey)
            try expect(!loaded.config.gateway.isReachableOffThisMac)
        }

        test("an upgraded document is written back so it migrates only once") {
            let url = tempURL("config.json")
            let json = """
            {"schemaVersion":1,"providers":[],"logicalModels":[],
             "gateway":{"port":8787,"bindAddress":"127.0.0.1","requireAPIKey":true,
             "localKeyRef":{"account":"gw"},"autoStart":true,"allowRemoteAccess":false,
             "maxConcurrentRequests":64,"allowedOrigins":[]}}
            """
            try Data(json.utf8).write(to: url)
            let first = ConfigStore(url: url)
            let loaded = first.load()
            try expect(!loaded.config.gateway.requireAPIKey, "an upgraded config must not ask clients for a key")
            try expect(first.didUpgradeSchema)
            try first.save(loaded.config)

            let second = ConfigStore(url: url)
            let again = second.load()
            try expect(!second.didUpgradeSchema, "the same document must not be migrated twice")
            try expect(again.warnings.isEmpty)
            try expectEqual(again.config.schemaVersion, DerbyConfig.currentSchemaVersion)
        }

        test("a newer schema version is tolerated with a warning") {
            var raw: [String: Any] = ["schemaVersion": 99]
            let notes = ConfigMigrator.migrate(rawObject: &raw)
            try expectEqual(raw["schemaVersion"] as? Int, DerbyConfig.currentSchemaVersion)
            try expect(!notes.isEmpty)
            try expectContains(notes[0], "newer version")
        }

        test("export omits secrets and import reports what must be re-entered") {
            let account = ProviderAccount(name: "OpenAI", kind: .openai, auth: .apiKey(SecretRef(account: "r")))
            let config = DerbyConfig(providers: [account], logicalModels: DerbyConfig.defaultLogicalModels())
            let data = try ConfigStore.export(config)
            let text = String(decoding: data, as: UTF8.self)
            try expectContains(text, "_derbyExport")
            try expectContains(text, "\"containsSecrets\" : false")

            let (imported, warnings) = try ConfigStore.importConfig(from: data)
            try expectEqual(imported.providers.count, 1)
            try expectEqual(imported.logicalModels.count, 5)
            try expect(warnings.contains { $0.contains("credentials re-entered") })
        }

        test("logical model names must be unique and non-empty") {
            let config = DerbyConfig(logicalModels: [LogicalModel(name: "coding")])
            try expect(!config.isLogicalModelNameAvailable("coding"))
            try expect(!config.isLogicalModelNameAvailable("CODING"))
            try expect(!config.isLogicalModelNameAvailable("   "))
            try expect(config.isLogicalModelNameAvailable("fast"))
            try expect(config.isLogicalModelNameAvailable("coding", excluding: config.logicalModels[0].id))
        }
    }

    suite("Persistence / secrets") {
        test("the in-memory store round-trips and prunes") {
            let store = InMemorySecretStore()
            let a = SecretRef(account: "a"), b = SecretRef(account: "b")
            try store.set("value-a", for: a)
            try store.set("value-b", for: b)
            try expectEqual(store.get(a), "value-a")
            try expect(store.has(b))
            store.prune(keeping: [a])
            try expectNil(store.get(b))
            try expectEqual(store.get(a), "value-a")
            try store.set(nil, for: a)
            try expect(!store.has(a))
        }

        test("the Keychain store round-trips a value") {
            // Uses a throwaway service so it cannot disturb real Derby secrets.
            let service = "com.derby.tests.\(UUID().uuidString)"
            let store = KeychainSecretStore(service: service)
            let ref = SecretRef(account: "unit-test")
            do {
                try store.set("sk-keychain-round-trip", for: ref)
                try expectEqual(store.get(ref), "sk-keychain-round-trip")
                try expectEqual(store.fingerprint(ref), "sk-k…trip", "fingerprints must not reveal the middle")
                // Short values are masked entirely rather than partially leaked.
                let short = SecretRef(account: "unit-test-short")
                try store.set("abc123", for: short)
                try expectEqual(store.fingerprint(short), "••••••")
                try store.delete(short)
                try store.delete(ref)
                try expectNil(store.get(ref))
            } catch {
                // Keychain access can be denied in a sandboxed CI context; the
                // in-memory store covers the contract in that case.
                throw TestFailure(message: "keychain unavailable: \(error)", file: #fileID, line: #line)
            }
        }
    }

    suite("Persistence / telemetry store") {
        test("records, queries and aggregates request history") {
            let url = tempURL("t.sqlite3")
            let store = TelemetryStore(path: url.path, settings: LoggingSettings(level: .debug))
            try await store.open()

            for i in 0..<5 {
                var record = RequestRecord(id: "req_\(i)", createdAt: Date(),
                                           logicalModel: i < 3 ? "coding" : "fast",
                                           requestedModel: "coding", clientName: "curl",
                                           succeeded: i != 4,
                                           finalProviderName: i < 3 ? "Alpha" : "Beta",
                                           finalModelID: "m\(i % 2)",
                                           totalSeconds: Double(i) * 0.1 + 0.1,
                                           usage: CanonicalUsage(inputTokens: 100, outputTokens: 10),
                                           costUSD: 0.01,
                                           failoverCount: i == 2 ? 1 : 0)
                record.attempts = [AttemptRecord(id: "attempt_1", index: 0, providerID: UUID(),
                                                 providerName: "Alpha", providerKind: "openai",
                                                 modelID: "m", targetLabel: "Alpha · m",
                                                 status: .success, startedAt: Date(), durationSeconds: 0.2)]
                await store.record(record)
            }

            let all = await store.requests(RequestQuery())
            try expectEqual(all.count, 5)
            try expectEqual(all.first?.attempts.count, 1, "attempt detail must survive the round trip")

            var failuresOnly = RequestQuery()
            failuresOnly.onlyFailures = true
            try expectEqual(await store.requests(failuresOnly).count, 1)

            var failoversOnly = RequestQuery()
            failoversOnly.onlyFailovers = true
            try expectEqual(await store.requests(failoversOnly).count, 1)

            var byModel = RequestQuery()
            byModel.logicalModel = "coding"
            try expectEqual(await store.requests(byModel).count, 3)

            let usage = await store.usage(window: .all)
            try expectEqual(usage.totalRequests, 5)
            try expectEqual(usage.successes, 4)
            try expectEqual(usage.inputTokens, 500)
            try expectClose(usage.costUSD, 0.05, tolerance: 1e-6)
            try expectEqual(usage.byLogicalModel.first { $0.key == "coding" }?.requests, 3)
            try expectEqual(usage.byProvider.first { $0.key == "Alpha" }?.requests, 3)
            try expectEqual(usage.byClient.first?.key, "curl")

            await store.close()
        }

        test("logs are written, filtered by level and redacted") {
            let url = tempURL("t2.sqlite3")
            let store = TelemetryStore(path: url.path, settings: LoggingSettings(level: .info))
            try await store.open()
            await store.log(LogEntry(level: .debug, category: "x", message: "chatty"))
            await store.log(LogEntry(level: .warn, category: "provider",
                                     message: "failed with key sk-abcdefghijklmnop"))
            let logs = await store.logs(level: .debug)
            try expectEqual(logs.count, 1, "debug lines must be dropped below the configured level")
            try expect(!logs[0].message.contains("sk-abcdefghijklmnop"))
            await store.close()
        }

        test("retention pruning trims old rows") {
            let url = tempURL("t3.sqlite3")
            let store = TelemetryStore(path: url.path,
                                       settings: LoggingSettings(historyRetentionDays: 1, maxHistoryRows: 100))
            try await store.open()
            await store.record(RequestRecord(id: "old", createdAt: Date().addingTimeInterval(-3 * 86400)))
            await store.record(RequestRecord(id: "new", createdAt: Date()))
            await store.pruneNow()
            let remaining = await store.requests(RequestQuery())
            try expectEqual(remaining.count, 1)
            try expectEqual(remaining.first?.id, "new")
            await store.close()
        }
    }
}

/// Registered from `registerPersistenceTests` via `registerCredentialTests`.
func registerCredentialTests() {
    suite("Credentials / source selection") {
        func cred(_ token: String, expiresIn: TimeInterval?, source: CredentialOrigin) -> CLICredential {
            CLICredential(accessToken: token,
                          refreshToken: "r-\(token)",
                          expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
                          source: source)
        }

        test("the copy that expires latest wins") {
            // Claude Code writes the Keychain on macOS but often leaves an old
            // ~/.claude/.credentials.json behind. Reading the stale file first
            // meant refreshing with a superseded token and getting HTTP 400.
            let stale = cred("old", expiresIn: -3600,
                             source: .file(URL(fileURLWithPath: "/tmp/.credentials.json")))
            let live = cred("new", expiresIn: 3600,
                            source: .keychain(service: "Claude Code-credentials", account: nil))
            let picked = try expectNotNil(CLICredentialReader.freshest(of: [stale, live]))
            try expectEqual(picked.accessToken, "new")
            try expect(!picked.isExpired())
            guard case .keychain = try expectNotNil(picked.source) else {
                throw TestFailure(message: "expected the Keychain copy to win", file: #fileID, line: #line)
            }
        }

        test("order of discovery does not matter") {
            let stale = cred("old", expiresIn: -60, source: .file(URL(fileURLWithPath: "/tmp/a")))
            let live = cred("new", expiresIn: 60, source: .file(URL(fileURLWithPath: "/tmp/b")))
            try expectEqual(CLICredentialReader.freshest(of: [stale, live])?.accessToken, "new")
            try expectEqual(CLICredentialReader.freshest(of: [live, stale])?.accessToken, "new")
        }

        test("a copy with a recorded expiry beats one without") {
            let undated = cred("undated", expiresIn: nil, source: .file(URL(fileURLWithPath: "/tmp/a")))
            let dated = cred("dated", expiresIn: -10, source: .file(URL(fileURLWithPath: "/tmp/b")))
            try expectEqual(CLICredentialReader.freshest(of: [undated, dated])?.accessToken, "dated")
        }

        test("no candidates yields nothing") {
            try expectNil(CLICredentialReader.freshest(of: []))
        }

        test("expiry is read with a skew so a token never races its own deadline") {
            let almost = cred("x", expiresIn: 30, source: .file(URL(fileURLWithPath: "/tmp/a")))
            try expect(almost.isExpired(skew: 60), "a token expiring in 30s must not be treated as usable")
            try expect(!almost.isExpired(skew: 0))
        }

        test("origin is reported for display") {
            let c = cred("x", expiresIn: 60, source: .keychain(service: "Claude Code-credentials", account: nil))
            try expectContains(c.origin, "Keychain")
        }
    }
}

func registerForwardCompatibilityTests() {
    suite("Persistence / forward compatibility") {
        test("a model saved before newer capability fields still decodes") {
            // The exact shape written by earlier builds. Adding a non-optional
            // property to `ModelCapabilities` once made this undecodable, which
            // silently emptied the entire providers array.
            let json = """
            {"flags":["text","vision","tools","streaming"],
             "contextWindow":200000,"maxOutputTokens":64000,"source":"builtin"}
            """
            let caps = try JSONDecoder().decode(ModelCapabilities.self, from: Data(json.utf8))
            try expectEqual(caps.contextWindow, 200_000)
            try expect(caps.flags.contains(.vision))
            try expect(caps.unsupportedParameters.isEmpty, "an absent deny-list means nothing is denied")
            try expectNil(caps.supportedReasoningEfforts)
        }

        test("an entire provider written by an earlier build still decodes") {
            let json = """
            {"id":"\(UUID().uuidString)","name":"Claude subscription","kind":"anthropic_subscription",
             "enabled":true,"auth":{"cli":{"source":"claude_code","allowRefresh":false}},
             "extraHeaders":{},"requestTimeoutSeconds":300,"connectTimeoutSeconds":10,
             "rateLimits":{"maxConcurrentRequests":2},
             "models":[{"id":"\(UUID().uuidString)","modelID":"claude-sonnet-5","enabled":true,
                        "capabilities":{"flags":["text","streaming"],"source":"unknown"},
                        "capabilityOverrides":{},"qualityScore":90}],
             "notes":"","createdAt":"2026-09-01T00:00:00Z","allowInsecureTLS":false,
             "preferenceScore":70}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let account = try decoder.decode(ProviderAccount.self, from: Data(json.utf8))
            try expectEqual(account.models.count, 1)
            try expectEqual(account.models[0].modelID, "claude-sonnet-5")
            try expectNil(account.credentialHomeOverride)
            try expectNil(account.models[0].profile)
        }

        test("a section that cannot be read is reported, not silently dropped") {
            // Tolerance is right; silence is not. Losing five configured providers
            // with no message is far worse than starting with a visible warning.
            let json = """
            {"schemaVersion":1,"providers":"this is not an array","logicalModels":[]}
            """
            let config = try JSONDecoder().decode(DerbyConfig.self, from: Data(json.utf8))
            try expect(config.providers.isEmpty)
            try expect(config.decodeFailures.contains { $0.contains("providers") },
                       "the failure must be recorded so the user is told")
        }

        test("a config that reads cleanly reports no failures") {
            let data = try ConfigStore.export(DerbyConfig.seeded())
            let (config, _) = try ConfigStore.importConfig(from: data)
            try expect(config.decodeFailures.isEmpty)
        }

        test("loading a damaged section warns and preserves the original file") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-decode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("config.json")
            try Data(#"{"schemaVersion":1,"providers":42,"logicalModels":[]}"#.utf8).write(to: url)

            let loaded = ConfigStore(url: url).load()
            try expect(!loaded.isFirstRun)
            try expect(loaded.warnings.contains { $0.contains("could not be read") },
                       "the user must be told which part was reset")
            try expect(FileManager.default.fileExists(atPath: url.path),
                       "the original must survive so nothing is lost")
        }
    }
}
