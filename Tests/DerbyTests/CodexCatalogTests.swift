import Foundation
@testable import DerbyCore

func registerCodexCatalogTests() {
    /// Mirrors the real `~/.codex/models_cache.json` shape.
    func writeCache(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("models_cache.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    suite("Reasoning effort scale") {
        test("the scale is ordered and open past the classic four levels") {
            try expect(ReasoningEffort.minimal < ReasoningEffort.medium)
            try expect(ReasoningEffort.high < ReasoningEffort.xhigh)
            try expect(ReasoningEffort.xhigh < ReasoningEffort.max)
            try expect(ReasoningEffort.max < ReasoningEffort.ultra)
            try expect(ReasoningEffort.allCases.count == 7)
        }

        test("levels stronger than OpenAI's REST scale map down to high") {
            // Sending "ultra" to the OpenAI REST API would be rejected.
            try expectEqual(ReasoningEffort.ultra.standardOpenAIValue, "high")
            try expectEqual(ReasoningEffort.max.standardOpenAIValue, "high")
            try expectEqual(ReasoningEffort.xhigh.standardOpenAIValue, "high")
            try expectEqual(ReasoningEffort.medium.standardOpenAIValue, "medium")
        }

        test("thinking budgets increase monotonically") {
            let budgets = ReasoningEffort.allCases.sorted().map(\.thinkingBudget)
            try expectEqual(budgets, budgets.sorted(), "a stronger effort must never get a smaller budget")
        }

        test("descendingFrom walks down to weaker levels only") {
            try expectEqual(ReasoningEffort.descendingFrom(.high), [.high, .medium, .low, .minimal])
            try expectEqual(ReasoningEffort.descendingFrom(.minimal), [.minimal])
        }

        test("the OpenAI adapter never sends an unsupported level") {
            let adapter = OpenAIAdapter()
            var quirks = OpenAIQuirks()
            quirks.supportsReasoningEffort = true
            var r = CanonicalRequest(requestedModel: "l")
            r.reasoning = ReasoningControls(effort: .ultra)
            let body = try adapter.buildChatBody(r, model: "gpt-test", quirks: quirks, stream: false)
            try expectEqual(body["reasoning_effort"]?.stringValue, "high")
        }

        test("Anthropic derives a thinking budget below max_tokens") {
            let adapter = AnthropicAdapter(oauth: false)
            var r = CanonicalRequest(requestedModel: "l")
            r.maxOutputTokens = 8000
            r.reasoning = ReasoningControls(effort: .ultra)
            let account = Fixture.account("A", kind: .anthropic, models: [Fixture.model("claude-x")])
            let ctx = ProviderContext(account: account, transport: MockTransport(),
                                      secrets: InMemorySecretStore(), credentials: CredentialCache())
            let body = try adapter.buildBody(r, model: "claude-x", ctx: ctx, stream: false)
            let budget = try expectNotNil(body["thinking"]?["budget_tokens"]?.intValue)
            try expect(budget < 8000)
        }
    }

    suite("Codex catalog") {
        let sample = """
        {"fetched_at":"2026-08-27T02:05:12.219528Z","client_version":"0.147.0","models":[
          {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"flagship","priority":1,
           "visibility":"list","supported_in_api":true,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},
                                         {"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
          {"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","description":"","priority":3,
           "visibility":"list","supported_in_api":true,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},
                                         {"effort":"xhigh"},{"effort":"max"}]},
          {"slug":"gpt-reserve","display_name":"GPT-Reserve","description":"","priority":3,
           "visibility":"hide","supported_in_api":true,
           "supported_reasoning_levels":[{"effort":"medium"}]},
          {"slug":"gpt-5.4-mini","display_name":"GPT-5.4-Mini","description":"","priority":23,
           "visibility":"list","supported_in_api":true,
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]}
        ]}
        """

        test("parses the cache, ranks by priority and hides internal models") {
            let url = try writeCache(sample)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let catalog = try expectNotNil(CodexModelCatalog.parse(contentsOf: url))
            try expectEqual(catalog.entries.count, 4)
            try expectEqual(catalog.clientVersion, "0.147.0")
            try expect(catalog.fetchedAt != nil, "fractional-second timestamps must parse")

            let selectable = catalog.entries.filter { $0.isListed && $0.supportedInAPI }
            try expectEqual(selectable.map(\.slug), ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.4-mini"])
            try expectEqual(selectable.first?.displayName, "GPT-5.6-Sol")
            try expect(!selectable.contains { $0.slug == "gpt-reserve" }, "hidden models must not be offered")
        }

        test("quality follows the provider's own ranking") {
            let url = try writeCache(sample)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let entries = try expectNotNil(CodexModelCatalog.parse(contentsOf: url)).entries
            let sol = try expectNotNil(entries.first { $0.slug == "gpt-5.6-sol" })
            let mini = try expectNotNil(entries.first { $0.slug == "gpt-5.4-mini" })
            try expect(sol.derivedQuality > mini.derivedQuality, "the flagship must outrank the mini")
            try expect(sol.derivedQuality <= 100 && mini.derivedQuality >= 50)
        }

        test("effort is clamped to what each model supports") {
            let url = try writeCache(sample)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let catalog = try expectNotNil(CodexModelCatalog.parse(contentsOf: url))
            // Sol goes all the way to ultra.
            try expectEqual(CodexModelCatalog.clampEffort(.ultra, for: "gpt-5.6-sol", in: catalog), "ultra")
            // Luna stops at max, so ultra must step down rather than 400.
            try expectEqual(CodexModelCatalog.clampEffort(.ultra, for: "gpt-5.6-luna", in: catalog), "max")
            // Mini only knows low and medium.
            try expectEqual(CodexModelCatalog.clampEffort(.xhigh, for: "gpt-5.4-mini", in: catalog), "medium")
            try expectEqual(CodexModelCatalog.clampEffort(.low, for: "gpt-5.4-mini", in: catalog), "low")
        }

        test("an unknown model is left alone") {
            let url = try writeCache(sample)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let catalog = try expectNotNil(CodexModelCatalog.parse(contentsOf: url))
            try expectEqual(CodexModelCatalog.clampEffort(.high, for: "not-in-catalog", in: catalog), "high")
        }

        test("capabilities are taken from the catalog, not invented") {
            let url = try writeCache(sample)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let entry = try expectNotNil(
                CodexModelCatalog.parse(contentsOf: url)?.entries.first { $0.slug == "gpt-5.6-sol" })
            let caps = ChatGPTCodexAdapter.capabilities(for: entry)
            try expect(caps.flags.contains(.reasoning), "the catalog lists reasoning levels")
            try expect(caps.flags.contains(.tools))
            try expect(!caps.flags.contains(.vision), "vision is not stated by the catalog, so it is not claimed")
            try expectEqual(caps.source, .discovered)
        }

        test("a malformed or missing cache yields nothing rather than crashing") {
            let bad = try writeCache("{ not json")
            defer { try? FileManager.default.removeItem(at: bad.deletingLastPathComponent()) }
            try expectNil(CodexModelCatalog.parse(contentsOf: bad))
            try expectNil(CodexModelCatalog.parse(contentsOf: URL(fileURLWithPath: "/nope/models_cache.json")))
        }

        test("parses the real Codex cache when this machine has one") {
            // An integration smoke test: it exercises the parser against whatever
            // the installed CLI actually wrote, and is inert on machines with no
            // Codex install so the suite stays hermetic.
            let url = CodexModelCatalog.cacheURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let catalog = try expectNotNil(CodexModelCatalog.parse(contentsOf: url),
                                           "a real models_cache.json failed to parse")
            let selectable = catalog.entries.filter { $0.isListed && $0.supportedInAPI }
            try expect(!selectable.isEmpty, "the real cache produced no selectable models")
            try expectEqual(selectable, selectable.sorted { $0.priority < $1.priority },
                            "selectable models must come back best-first")
            try expect(selectable.allSatisfy { !$0.slug.isEmpty && !$0.displayName.isEmpty })
            if let flagship = selectable.first {
                try expect(flagship.derivedQuality >= 90, "the top-ranked model should score highly")
            }
        }

        test("subscription providers treat their catalog as authoritative") {
            try expect(ProviderKind.chatgptSubscription.hasAuthoritativeCatalog)
            try expect(ProviderKind.anthropicSubscription.hasAuthoritativeCatalog)
            try expect(!ProviderKind.openai.hasAuthoritativeCatalog)
            try expect(ProviderKind.chatgptSubscription.supportsModelDiscovery,
                       "discovery must be reachable, or a stale list can never be refreshed")
        }
    }
}
