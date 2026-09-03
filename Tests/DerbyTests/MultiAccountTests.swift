import Foundation
@testable import DerbyCore

func registerMultiAccountTests() {

    /// Builds an isolated CLI home containing a Codex-shaped auth.json.
    func makeCodexHome(account: String, expiresIn: TimeInterval = 3600) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A minimal unsigned JWT: the reader only reads claims, never verifies.
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = [
            "exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
            "https://api.openai.com/profile": ["email": "\(account)@example.com"],
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(account)",
                                            "chatgpt_plan_type": "plus"],
        ]
        let jwt = "\(segment(["alg": "none"])).\(segment(claims)).sig"
        let auth: [String: Any] = ["auth_mode": "chatgpt",
                                   "tokens": ["access_token": jwt,
                                              "id_token": jwt,
                                              "refresh_token": "refresh-\(account)",
                                              "account_id": "acct-\(account)"]]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: dir.appendingPathComponent("auth.json"))
        return dir
    }

    suite("Multiple accounts / credential homes") {
        test("each home yields its own account") {
            let a = try makeCodexHome(account: "alice")
            let b = try makeCodexHome(account: "bob")
            defer {
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            }
            let first = try CLICredentialReader.read(.codexCLI, home: a)
            let second = try CLICredentialReader.read(.codexCLI, home: b)
            try expectEqual(first.accountID, "acct-alice")
            try expectEqual(second.accountID, "acct-bob")
            try expect(first.accessToken != second.accessToken, "two homes must not share a token")
        }

        test("the account label identifies the login") {
            let home = try makeCodexHome(account: "alice")
            defer { try? FileManager.default.removeItem(at: home) }
            let cred = try CLICredentialReader.read(.codexCLI, home: home)
            let label = try expectNotNil(cred.accountLabel)
            try expectContains(label, "alice@example.com")
            try expectContains(label, "Plus")
        }

        test("the credential cache does not leak one account's token to another") {
            // Keying the cache on the source alone would return Alice's token for
            // Bob's provider — the whole feature would silently collapse.
            let a = try makeCodexHome(account: "alice")
            let b = try makeCodexHome(account: "bob")
            defer {
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            }
            let cache = CredentialCache()
            let first = try await cache.credential(for: .codexCLI, allowRefresh: false, home: a)
            let second = try await cache.credential(for: .codexCLI, allowRefresh: false, home: b)
            let firstAgain = try await cache.credential(for: .codexCLI, allowRefresh: false, home: a)
            try expectEqual(first.accountID, "acct-alice")
            try expectEqual(second.accountID, "acct-bob")
            try expectEqual(firstAgain.accountID, "acct-alice", "the cached entry must stay per-home")
        }

        test("an account resolves its own home from configuration") {
            var account = Fixture.account("ChatGPT — work", kind: .chatgptSubscription, models: [])
            account.credentialHomeOverride = "~/.codex-work"
            let resolved = try expectNotNil(account.credentialHomeURL)
            try expect(!resolved.path.contains("~"), "a tilde must be expanded")
            try expectContains(resolved.path, ".codex-work")

            account.credentialHomeOverride = nil
            try expectNil(account.credentialHomeURL, "no override means the CLI default")
            account.credentialHomeOverride = "   "
            try expectNil(account.credentialHomeURL, "blank is not an override")
        }

        test("a provider account decoded from older config has no override") {
            // The field is new; existing configurations must still load.
            let json = """
            {"id":"\(UUID().uuidString)","name":"ChatGPT","kind":"chatgpt_subscription",
             "enabled":true,"auth":{"cli":{"source":"codex_cli","allowRefresh":false}},
             "extraHeaders":{},"requestTimeoutSeconds":300,"connectTimeoutSeconds":10,
             "rateLimits":{"maxConcurrentRequests":2},"models":[],"notes":"",
             "createdAt":"2026-09-01T00:00:00Z","allowInsecureTLS":false,"preferenceScore":70}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let account = try decoder.decode(ProviderAccount.self, from: Data(json.utf8))
            try expectEqual(account.name, "ChatGPT")
            try expectNil(account.credentialHomeOverride)
        }

        test("two accounts of one service route as independent targets") {
            var work = Fixture.account("ChatGPT — work", kind: .chatgptSubscription,
                                       models: [Fixture.model("gpt-5.6-sol", quality: 95)])
            work.credentialHomeOverride = "~/.codex-work"
            var personal = Fixture.account("ChatGPT — personal", kind: .chatgptSubscription,
                                           models: [Fixture.model("gpt-5.6-sol", quality: 95)])
            personal.credentialHomeOverride = "~/.codex-personal"

            let config = Fixture.config(accounts: [work, personal],
                                        logicalModels: [Fixture.logical("smart", accounts: [work, personal])])
            let decision = try Fixture.decision(config, model: "smart")
            try expectEqual(decision.plan.attempts.count, 2)
            try expectEqual(Set(decision.plan.attempts.map { $0.target.providerName }),
                            ["ChatGPT — work", "ChatGPT — personal"])
            // Same model id, different accounts: the health keys must differ so one
            // account's rate limit cannot open the other's circuit.
            try expect(decision.plan.attempts[0].target.key != decision.plan.attempts[1].target.key)
        }

        test("a missing session names the exact command to run") {
            let empty = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-empty-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            let error = try await expectFailure(.authentication) {
                _ = try CLICredentialReader.read(.codexCLI, home: empty)
            }
            try expectContains(error.message, "CODEX_HOME=")
            try expectContains(error.message, empty.path)
        }

        test("home environment variables are known for the CLIs that support them") {
            try expectEqual(CLICredentialReader.homeEnvironmentVariable(for: .codexCLI), "CODEX_HOME")
            try expectEqual(CLICredentialReader.homeEnvironmentVariable(for: .claudeCode), "CLAUDE_CONFIG_DIR")
        }

        test("an isolated Claude home never falls back to the shared Keychain") {
            // Otherwise two Claude accounts would collapse onto one credential.
            let empty = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-claude-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            _ = try await expectFailure(.authentication) {
                _ = try CLICredentialReader.read(.claudeCode, home: empty)
            }
        }

        test("Derby reads an isolated home on this machine, not the default one") {
            // Integration smoke test: clone the real Codex home and prove the
            // adapter reads the copy. Inert without a Codex install.
            let real = CLICredentialReader.defaultHome(for: .codexCLI)
            guard FileManager.default.fileExists(atPath: real.appendingPathComponent("auth.json").path) else { return }

            let clone = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-clone-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: clone) }
            for file in ["auth.json", "models_cache.json"] {
                let from = real.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: from.path) {
                    try? FileManager.default.copyItem(at: from, to: clone.appendingPathComponent(file))
                }
            }

            let credential = try CLICredentialReader.read(.codexCLI, home: clone)
            guard case .file(let url) = try expectNotNil(credential.source) else {
                throw TestFailure(message: "expected a file-backed credential", file: #fileID, line: #line)
            }
            try expectContains(url.path, clone.path)
            try expect(!url.path.hasPrefix(real.path), "the default home must not have been consulted")

            // The catalog is per-home too, so the clone serves its own model list.
            if FileManager.default.fileExists(atPath: clone.appendingPathComponent("models_cache.json").path) {
                try expect(!CodexModelCatalog.selectableModels(home: clone).isEmpty,
                           "the cloned home should serve its own catalog")
            }
        }

        test("alternate homes include the default and report sign-in state") {
            let homes = LocalDiscovery.alternateHomes(for: .codexCLI)
            try expect(homes.contains { $0.isDefault }, "the default home must always be offered")
            try expect(homes.first?.isDefault == true, "the default should sort first")
            try expect(Set(homes.map(\.path)).count == homes.count, "no duplicate directories")
        }
    }
}
