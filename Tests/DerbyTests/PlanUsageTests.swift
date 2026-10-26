import Foundation
@testable import DerbyCore

func registerPlanUsageTests() {

    func context(_ account: ProviderAccount, _ transport: MockTransport) -> ProviderContext {
        ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                        credentials: CredentialCache(), attemptTimeout: 20)
    }

    /// A private Claude config directory: read from its file alone, never the
    /// Keychain, so the suite touches nothing the user owns.
    func claudeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("derby-usage-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let expiry = (Date().timeIntervalSince1970 + 3600) * 1000
        try #"{"claudeAiOauth":{"accessToken":"tok-usage","expiresAt":\#(expiry)}}"#
            .write(to: home.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        return home
    }

    func codexHome(account: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("derby-usage-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func segment(_ object: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = [
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-\(account)"],
        ]
        let jwt = "\(segment(["alg": "none"])).\(segment(claims)).sig"
        let auth: [String: Any] = ["auth_mode": "chatgpt",
                                   "tokens": ["access_token": jwt, "id_token": jwt,
                                              "refresh_token": "r", "account_id": "acct-\(account)"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: dir.appendingPathComponent("auth.json"))
        return dir
    }

    func window(_ usage: ProviderUsage, _ label: String) throws -> ProviderUsage.Window {
        try expectNotNil(usage.windows.first { $0.label == label },
                         "no \(label) window in \(usage.windows.map(\.label))")
    }

    suite("Plan usage / Claude subscription") {
        test("utilization is a percentage, so 1.0 is one percent") {
            let usage = ClaudePlanUsage.parse(try expectNotNil(JSONValue.parse("""
            {"five_hour":{"utilization":1.0,"resets_at":"2026-09-17T10:30:00.674190+00:00"},
             "seven_day":{"utilization":55.0,"resets_at":"2026-09-21T19:59:59Z"},
             "seven_day_opus":null,"seven_day_sonnet":null}
            """)))
            let five = try window(usage, "5-hour")
            try expectClose(try expectNotNil(five.usedFraction), 0.01)
            _ = try expectNotNil(five.resetsAt, "microsecond timestamps must parse")
            try expectClose(try expectNotNil(try window(usage, "Weekly").usedFraction), 0.55)
            try expectEqual(usage.windows.count, 2, "null per-model keys add nothing")
            try expectEqual(usage.source, .provider)
            try expect(!usage.isLimited)
        }

        test("per-model weekly caps come from either form, once") {
            let usage = ClaudePlanUsage.parse(try expectNotNil(JSONValue.parse("""
            {"five_hour":{"utilization":9.0,"resets_at":"2026-09-14T02:10:00Z"},
             "seven_day":{"utilization":68.0,"resets_at":"2026-09-19T09:00:00Z"},
             "seven_day_opus":{"utilization":12.0,"resets_at":null},
             "limits":[
               {"kind":"session","group":"session","percent":9,"is_active":false},
               {"kind":"weekly_all","group":"weekly","percent":68,"is_active":false},
               {"kind":"weekly_scoped","group":"weekly","percent":12,"is_active":false,
                "scope":{"model":{"id":null,"display_name":"Opus"}}},
               {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical",
                "is_active":true,"resets_at":"2026-09-19T09:00:00Z",
                "scope":{"model":{"id":null,"display_name":"Fable"}}}]}
            """)))
            try expectEqual(usage.windows.map(\.label), ["5-hour", "Weekly", "Weekly · Opus", "Weekly · Fable"])
            let fable = try window(usage, "Weekly · Fable")
            try expect(fable.isLimiting && fable.isExhausted)
            try expect(usage.isLimited, "a spent per-model cap is a limit even with the plan at 68%")
        }

        test("a subscription account reads the meter on the API host with its OAuth identity") {
            let home = try claudeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            await ClaudeCodeVersion.shared.seed("9.9.9")
            var account = ProviderAccount(name: "Claude sub", kind: .anthropicSubscription,
                                          auth: .cli(source: .claudeCode, allowRefresh: false))
            account.credentialHomeOverride = home.path
            let transport = MockTransport()
            transport.stub("/api/oauth/usage", json: #"{"five_hour":{"utilization":20}}"#)

            let usage = try expectNotNil(try await AnthropicAdapter(oauth: true).usage(context(account, transport)))
            try expectClose(try expectNotNil(try window(usage, "5-hour").usedFraction), 0.2)
            let sent = try expectNotNil(transport.requests.first)
            try expectEqual(sent.method, "GET")
            try expectEqual(sent.url.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            try expectEqual(sent.headers["authorization"], "Bearer tok-usage")
            try expectContains(try expectNotNil(sent.headers["anthropic-beta"]), "oauth-2025-04-20")
            try expectEqual(sent.headers["user-agent"], "claude-code/9.9.9 (external, cli)",
                            "the meter rate-limits clients it does not recognise")
        }

        test("a metered API key has no plan meter and asks for none") {
            let account = ProviderAccount(name: "Anthropic", kind: .anthropic,
                                          auth: .apiKey(SecretRef(account: "k")))
            let transport = MockTransport()
            try expectNil(try await AnthropicAdapter(oauth: false).usage(context(account, transport)))
            try expectEqual(transport.requests.count, 0)
        }

        test("only the default Claude login can raise a Keychain dialog") {
            // Which reads a background poll has to route around.
            try expect(CLICredentialReader.usesKeychain(.claudeCode, home: nil))
            try expect(!CLICredentialReader.usesKeychain(.claudeCode, home: URL(fileURLWithPath: "/tmp/c")))
            for source in [CLICredentialSource.codexCLI, .geminiCLI, .qwenCLI] {
                try expect(!CLICredentialReader.usesKeychain(source, home: nil), source.rawValue)
            }
            // A context says whether it may prompt; everything but a poll may.
            let account = ProviderAccount(name: "c", kind: .anthropicSubscription)
            try expect(context(account, MockTransport()).mayPromptForCredentials)
            let quiet = ProviderContext(account: account, transport: MockTransport(), secrets: InMemorySecretStore(),
                                        credentials: CredentialCache(), mayPromptForCredentials: false)
            try expect(!quiet.with(timeout: 5).mayPromptForCredentials, "carried through a retimed context")
        }

        test("a Claude Code CLI with its own config directory reads its meter from there") {
            let home = try claudeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            await ClaudeCodeVersion.shared.seed("9.9.9")
            var account = ProviderAccount(name: "Claude Code", kind: .claudeCodeCLI,
                                          auth: .cli(source: .claudeCode, allowRefresh: true))
            account.credentialHomeOverride = home.path
            let transport = MockTransport()
            transport.stub("/api/oauth/usage", json: #"{"seven_day":{"utilization":40}}"#)
            let usage = try expectNotNil(try await ClaudeCLIAdapter().usage(context(account, transport)))
            try expectClose(try expectNotNil(try window(usage, "Weekly").usedFraction), 0.4)
            try expectEqual(transport.requests.first?.url.host, "api.anthropic.com")
        }
    }

    suite("Plan usage / ChatGPT subscription") {
        test("windows are named by their length, not their slot") {
            // A weekly-only plan sends its one window in the primary slot.
            let weeklyOnly = ChatGPTCodexAdapter.parsePlanUsage(try expectNotNil(JSONValue.parse("""
            {"plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,
              "primary_window":{"used_percent":0,"limit_window_seconds":604800},
              "secondary_window":null}}
            """)))
            try expectEqual(weeklyOnly.windows.map(\.label), ["Weekly"])
            try expectEqual(weeklyOnly.plan, "Pro Lite")

            let both = ChatGPTCodexAdapter.parsePlanUsage(try expectNotNil(JSONValue.parse("""
            {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
              "primary_window":{"used_percent":38,"limit_window_seconds":18000,
                                "reset_after_seconds":3600,"reset_at":4102444800},
              "secondary_window":{"used_percent":21,"limit_window_seconds":604800,
                                  "reset_after_seconds":86400,"reset_at":4102444800}}}
            """)))
            try expectEqual(both.windows.map(\.label), ["5-hour", "Weekly"])
            try expectClose(try expectNotNil(both.windows[0].usedFraction), 0.38)
            try expectEqual(both.windows[0].resetsAt, Date(timeIntervalSince1970: 4_102_444_800))
            try expectEqual(both.plan, "Plus")
        }

        test("a model-level limit can be spent while the account's windows read zero") {
            let usage = ChatGPTCodexAdapter.parsePlanUsage(try expectNotNil(JSONValue.parse("""
            {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
              "primary_window":{"used_percent":0,"limit_window_seconds":18000}},
             "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"spark",
               "rate_limit":{"allowed":false,"limit_reached":true,
                 "primary_window":{"used_percent":0,"limit_window_seconds":18000},
                 "secondary_window":{"used_percent":100,"limit_window_seconds":604800}}}],
             "credits":{"has_credits":true,"unlimited":false,"balance":"12.5"}}
            """)))
            let spark = try window(usage, "Weekly · GPT-5.3-Codex-Spark")
            try expect(spark.isExhausted)
            try expect(usage.isLimited)
            try expectEqual(usage.amounts, [ProviderUsage.Amount(label: "Credits", value: 12.5, unit: .credits)])
        }

        test("the meter sits beside codex/ under the ChatGPT backend") {
            try expectEqual(try ChatGPTCodexAdapter.usageURL(base: "https://chatgpt.com/backend-api/codex").absoluteString,
                            "https://chatgpt.com/backend-api/wham/usage")
            try expectEqual(try ChatGPTCodexAdapter.usageURL(base: "https://codex.example.com").absoluteString,
                            "https://codex.example.com/api/codex/usage")
        }

        test("each ChatGPT login reads its own meter") {
            let home = try codexHome(account: "work")
            defer { try? FileManager.default.removeItem(at: home) }
            var account = ProviderAccount(name: "ChatGPT work", kind: .chatgptSubscription,
                                          auth: .cli(source: .codexCLI, allowRefresh: false))
            account.credentialHomeOverride = home.path
            let transport = MockTransport()
            transport.stub("/wham/usage", json: #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}}}"#)
            let usage = try expectNotNil(try await ChatGPTCodexAdapter().usage(context(account, transport)))
            try expectEqual(usage.windows.map(\.label), ["5-hour"])
            let sent = try expectNotNil(transport.requests.first)
            try expectEqual(sent.method, "GET")
            try expectEqual(sent.headers["chatgpt-account-id"], "acct-work")
        }
    }

    suite("Plan usage / metered APIs") {
        test("OpenRouter reports the key's limit and what it spent") {
            let secrets = InMemorySecretStore(["or": "sk-or"])
            let account = ProviderAccount(name: "OpenRouter", kind: .openrouter, auth: .apiKey(SecretRef(account: "or")))
            let transport = MockTransport()
            transport.stub("/api/v1/key", json: """
            {"data":{"limit":10,"limit_remaining":7.5,"limit_reset":"monthly","usage":2.5,
                     "usage_daily":0.4,"usage_weekly":1.1,"usage_monthly":2.5,"is_free_tier":false}}
            """)
            transport.stub("/api/v1/credits", status: 403, json: #"{"error":{"message":"forbidden"}}"#)
            let ctx = ProviderContext(account: account, transport: transport, secrets: secrets,
                                      credentials: CredentialCache())
            let usage = try expectNotNil(try await OpenAIAdapter().usage(ctx))
            let key = try window(usage, "Monthly key limit")
            try expectClose(try expectNotNil(key.usedFraction), 0.25)
            try expectEqual(key.unit, .usd)
            try expectEqual(usage.amounts.map(\.label), ["Today", "This week", "This month"],
                            "a key that may not read the account balance still reports its own limit")
            try expectEqual(transport.requests.first?.headers["authorization"], "Bearer sk-or")
        }

        test("DeepSeek reports its balance from the host root") {
            let secrets = InMemorySecretStore(["ds": "sk-ds"])
            let account = ProviderAccount(name: "DeepSeek", kind: .deepseek, auth: .apiKey(SecretRef(account: "ds")))
            let transport = MockTransport()
            transport.stub("/user/balance", json: """
            {"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00",
              "granted_balance":"0.00","topped_up_balance":"0.00"}]}
            """)
            let ctx = ProviderContext(account: account, transport: transport, secrets: secrets,
                                      credentials: CredentialCache())
            let usage = try expectNotNil(try await OpenAIAdapter().usage(ctx))
            try expectEqual(usage.amounts, [ProviderUsage.Amount(label: "Balance", value: 0, unit: .currency("CNY"))])
            try expect(usage.isLimited, "the provider says the balance cannot pay for a call")
            try expectEqual(transport.requests.first?.url.absoluteString, "https://api.deepseek.com/user/balance")
        }

        test("providers that publish nothing to an inference key are not asked") {
            for kind in [ProviderKind.qwen, .groq, .openai, .openAICompatible, .mistral] {
                let account = ProviderAccount(name: kind.displayName, kind: kind, baseURLOverride: "https://x.example/v1",
                                              auth: .none)
                let transport = MockTransport()
                try expectNil(try await OpenAIAdapter().usage(context(account, transport)), kind.rawValue)
                try expectEqual(transport.requests.count, 0, kind.rawValue)
            }
        }
    }

    suite("Plan usage / Derby's own count") {
        test("an idle account with no declared limit shows nothing") {
            try expectNil(ProviderUsage.counted(tallies: [:], limits: RateLimitConfig()))
        }

        test("traffic without a limit is a count, not a fraction") {
            let usage = try expectNotNil(ProviderUsage.counted(
                tallies: ["counted.5h": .init(requests: 12), "counted.7d": .init(requests: 300)],
                limits: RateLimitConfig()))
            try expectEqual(usage.source, .counted)
            try expectEqual(usage.windows.map(\.label), ["5-hour", "7-day"],
                            "no 30-day window unless a monthly limit asks for one")
            try expectNil(usage.windows[0].usedFraction)
            try expectEqual(usage.windows[1].used, 300)
        }

        test("declared limits turn the count into a meter") {
            var limits = RateLimitConfig()
            limits.planRequestsPer5Hours = 6000
            limits.planRequestsPerMonth = 90000
            let usage = try expectNotNil(ProviderUsage.counted(
                tallies: ["counted.5h": .init(requests: 1500), "counted.30d": .init(requests: 90000)],
                limits: limits))
            try expectEqual(usage.windows.map(\.label), ["5-hour", "7-day", "30-day"])
            try expectClose(try expectNotNil(usage.windows[0].usedFraction), 0.25)
            try expectNil(usage.windows[1].usedFraction, "no weekly limit was declared")
            try expect(usage.windows[2].isExhausted)
        }

        test("windows are named by length") {
            try expectEqual(ProviderUsage.label(forWindowSeconds: 18_000), "5-hour")
            try expectEqual(ProviderUsage.label(forWindowSeconds: 604_800), "Weekly")
            try expectEqual(ProviderUsage.label(forWindowSeconds: 86_400), "Daily")
            try expectEqual(ProviderUsage.label(forWindowSeconds: 30 * 86_400), "Monthly")
            try expectEqual(ProviderUsage.label(forWindowSeconds: 3 * 3600), "3-hour")
            try expectEqual(ProviderUsage.label(forWindowSeconds: 3 * 86_400), "3-day")
        }

        test("reset times parse in every form meters write them") {
            let expected = Date(timeIntervalSince1970: 1_789_000_000)
            try expectEqual(UsageTime.date(.number(1_789_000_000)), expected)
            try expectEqual(UsageTime.date(.number(1_789_000_000_000)), expected, "milliseconds")
            try expectEqual(UsageTime.date(.string("2026-09-10T00:26:40Z")), expected)
            try expectEqual(UsageTime.date(.string("2026-09-10T00:26:40.123456+00:00"))
                                .map { $0.timeIntervalSince1970.rounded(.down) },
                            1_789_000_000)
            try expectNil(UsageTime.date(.null))
        }

        test("history is tallied per account that answered, successes only") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("derby-tally-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = TelemetryStore(path: dir.appendingPathComponent("t.sqlite3").path)
            try await store.open()
            let qwen = UUID(), other = UUID()
            let now = Date()
            await store.record(RequestRecord(createdAt: now, succeeded: true, finalProviderID: qwen,
                                             usage: CanonicalUsage(inputTokens: 100, outputTokens: 20)))
            await store.record(RequestRecord(createdAt: now, succeeded: true, finalProviderID: qwen))
            await store.record(RequestRecord(createdAt: now, succeeded: false, finalProviderID: qwen))
            await store.record(RequestRecord(createdAt: now.addingTimeInterval(-6 * 3600), succeeded: true,
                                             finalProviderID: qwen))
            await store.record(RequestRecord(createdAt: now, succeeded: true, finalProviderID: other))
            let recent = await store.requestTallies(since: now.addingTimeInterval(-5 * 3600))
            try expectEqual(recent[qwen], ProviderUsage.Tally(requests: 2, tokens: 120))
            try expectEqual(recent[other]?.requests, 1)
            try expectEqual(await store.requestTallies(since: now.addingTimeInterval(-7 * 86_400))[qwen]?.requests, 3)
            await store.close()
        }
    }

    suite("Plan usage / monitor") {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var names: [String] = []
            func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        }

        func claudeAccounts() -> (cli: ProviderAccount, direct: ProviderAccount) {
            (ProviderAccount(name: "Claude Code", kind: .claudeCodeCLI,
                             auth: .cli(source: .claudeCode, allowRefresh: true)),
             ProviderAccount(name: "Claude direct", kind: .anthropicSubscription,
                             auth: .cli(source: .claudeCode, allowRefresh: false)))
        }
        let meter = ProviderUsage(windows: [.init(id: "five_hour", label: "5-hour", usedFraction: 0.3)])

        test("accounts on one login are read once and share the answer") {
            let (cli, direct) = claudeAccounts()
            let calls = Calls()
            let monitor = UsageMonitor(
                accounts: { [cli, direct] },
                fetch: { account, _ in
                    calls.add(account.name)
                    // The CLI declines, so the direct-API account reads for both.
                    return account.kind == .claudeCodeCLI ? nil : meter
                },
                tallies: { _ in [:] })
            await monitor.refresh()
            try expectEqual(calls.all, ["Claude Code", "Claude direct"])
            let statuses = await monitor.snapshot()
            try expectEqual(statuses[cli.id]?.usage, meter)
            try expectEqual(statuses[direct.id]?.usage, meter)
        }

        test("separate logins of one kind are read separately") {
            let work = ProviderAccount(name: "work", kind: .chatgptSubscription,
                                       auth: .cli(source: .codexCLI, allowRefresh: true),
                                       credentialHomeOverride: "/tmp/codex-work")
            let personal = ProviderAccount(name: "personal", kind: .chatgptSubscription,
                                           auth: .cli(source: .codexCLI, allowRefresh: true))
            let calls = Calls()
            let monitor = UsageMonitor(accounts: { [work, personal] },
                                       fetch: { account, _ in calls.add(account.name); return meter },
                                       tallies: { _ in [:] })
            await monitor.refresh()
            try expectEqual(Set(calls.all), ["work", "personal"])
        }

        test("a failed read keeps the last good report and says why") {
            let account = ProviderAccount(name: "ChatGPT", kind: .chatgptSubscription,
                                          auth: .cli(source: .codexCLI, allowRefresh: true))
            final class Toggle: @unchecked Sendable { var fail = false }
            let toggle = Toggle()
            let monitor = UsageMonitor(
                accounts: { [account] },
                fetch: { _, _ in
                    if toggle.fail { throw DerbyError(kind: .rateLimit, message: "slow down", providerStatus: 429) }
                    return meter
                },
                tallies: { _ in [:] })
            let start = Date()
            await monitor.refresh(now: start)
            toggle.fail = true
            await monitor.refresh(now: start.addingTimeInterval(UsageMonitor.pollInterval + 1))
            let status = try expectNotNil(await monitor.snapshot()[account.id])
            try expectEqual(status.usage, meter)
            try expectEqual(status.error, "slow down")
        }

        test("a provider with no meter gets Derby's count; local servers get nothing") {
            let qwen = ProviderAccount(name: "Qwen Cloud", kind: .qwen, auth: .apiKey(SecretRef(account: "q")))
            let local = ProviderAccount(name: "Ollama", kind: .ollama, auth: .none)
            let off = ProviderAccount(name: "Off", kind: .qwen, enabled: false, auth: .none)
            let calls = Calls()
            let monitor = UsageMonitor(
                accounts: { [qwen, local, off] },
                fetch: { account, _ in calls.add(account.name); return nil },
                tallies: { _ in [qwen.id: .init(requests: 42), local.id: .init(requests: 9)] })
            await monitor.refresh()
            try expectEqual(calls.all, ["Qwen Cloud"])
            let statuses = await monitor.snapshot()
            let usage = try expectNotNil(statuses[qwen.id]?.usage)
            try expectEqual(usage.source, .counted)
            try expectEqual(usage.windows.first?.used, 42)
            try expectNil(statuses[local.id])
            try expectNil(statuses[off.id])
        }

        test("meters are not re-read before they are due, even on demand") {
            let account = ProviderAccount(name: "ChatGPT", kind: .chatgptSubscription,
                                          auth: .cli(source: .codexCLI, allowRefresh: true))
            let calls = Calls()
            let monitor = UsageMonitor(accounts: { [account] },
                                       fetch: { account, _ in calls.add(account.name); return meter },
                                       tallies: { _ in [:] })
            let start = Date()
            await monitor.refresh(now: start)
            await monitor.refresh(now: start.addingTimeInterval(UsageMonitor.tickInterval))
            try expectEqual(calls.all.count, 1, "a tick is not a poll")
            await monitor.refresh(force: true, now: start.addingTimeInterval(5))
            try expectEqual(calls.all.count, 1, "a manual refresh right after a read reuses it")
            await monitor.refresh(force: true, now: start.addingTimeInterval(UsageMonitor.minimumRefreshInterval + 1))
            try expectEqual(calls.all.count, 2)
            await monitor.refresh(now: start.addingTimeInterval(UsageMonitor.pollInterval + 60))
            try expectEqual(calls.all.count, 3)
        }

        test("only a manual refresh may prompt for a login") {
            let account = ProviderAccount(name: "Claude", kind: .anthropicSubscription,
                                          auth: .cli(source: .claudeCode, allowRefresh: false))
            let calls = Calls()
            let monitor = UsageMonitor(accounts: { [account] },
                                       fetch: { _, interactive in calls.add("\(interactive)"); return meter },
                                       tallies: { _ in [:] })
            let start = Date()
            await monitor.refresh(now: start)
            await monitor.refresh(force: true, now: start.addingTimeInterval(UsageMonitor.minimumRefreshInterval + 1))
            try expectEqual(calls.all, ["false", "true"])
        }

        test("a login not read yet is retried at the next tick, a refusal waits the interval") {
            let local = ProviderAccount(name: "no login yet", kind: .anthropicSubscription,
                                        auth: .cli(source: .claudeCode, allowRefresh: false))
            let refused = ProviderAccount(name: "refused", kind: .chatgptSubscription,
                                          auth: .cli(source: .codexCLI, allowRefresh: false))
            let calls = Calls()
            let monitor = UsageMonitor(
                accounts: { [local, refused] },
                fetch: { account, _ in
                    calls.add(account.name)
                    if account.name == "refused" {
                        throw DerbyError(kind: .rateLimit, message: "429", providerStatus: 429)
                    }
                    throw DerbyError(kind: .authentication, message: "Derby has not read the login yet.")
                },
                tallies: { _ in [:] })
            let start = Date()
            await monitor.refresh(now: start)
            await monitor.refresh(now: start.addingTimeInterval(UsageMonitor.tickInterval))
            try expectEqual(calls.all.filter { $0 == "no login yet" }.count, 2)
            try expectEqual(calls.all.filter { $0 == "refused" }.count, 1)
            let status = try expectNotNil(await monitor.snapshot()[local.id])
            try expectContains(try expectNotNil(status.error), "not read the login")
        }

        test("a meter stuck where cancellation cannot reach it is abandoned at its deadline") {
            // A Keychain read waiting on a dialog ignores cancellation; the
            // task group inside `withDeadline` would wait it out.
            let started = Date()
            do {
                _ = try await withAbandoningDeadline(0.1, message: "stuck") { () -> Int in
                    usleep(1_000_000)
                    return 1
                }
                try expect(false, "expected a timeout")
            } catch let e as DerbyError {
                try expectEqual(e.kind, .timeout)
            }
            try expect(Date().timeIntervalSince(started) < 0.8, "returned at the deadline, not when the work did")
            try expectEqual(try await withAbandoningDeadline(5, message: "quick") { 7 }, 7)
        }
    }

    suite("Plan usage / keep-warm") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveHours = ProviderUsage.fiveHours

        /// A plan meter with a five-hour window in the given state, read at `now`.
        func meter(_ used: Double, resets: Date?, at now: Date, weekly: Double = 0.4) -> ProviderUsage {
            ProviderUsage(windows: [
                .init(id: "five_hour", label: "5-hour", usedFraction: used,
                      duration: fiveHours, resetsAt: resets),
                .init(id: "seven_day", label: "Weekly", usedFraction: weekly,
                      duration: ProviderUsage.week, resetsAt: now.addingTimeInterval(3 * 86_400)),
            ], observedAt: now)
        }

        func claude(_ name: String, kind: ProviderKind, keep: Bool? = nil) -> ProviderAccount {
            ProviderAccount(name: name, kind: kind, auth: .cli(source: .claudeCode, allowRefresh: false),
                            models: [PhysicalModel(modelID: "lead"), PhysicalModel(modelID: "side")],
                            keepPlanWindowRunning: keep)
        }

        /// A monitor over `accounts` whose meter answers `reading` and whose
        /// warm-ups are recorded (and fail when `failure` is set).
        func monitor(_ accounts: [ProviderAccount], reading: Locked<ProviderUsage?>,
                     sent: Locked<[String]>, logs: Locked<[String]>,
                     failure: Locked<DerbyError?> = Locked(nil)) -> UsageMonitor {
            UsageMonitor(
                accounts: { accounts },
                fetch: { account, _ in account.kind.isSubscription ? reading.value : nil },
                tallies: { _ in [:] },
                warm: { account in
                    sent.mutate { $0.append(account.name) }
                    if let error = failure.value { throw error }
                    return PlanWarmUp.Receipt(model: account.warmUpModel?.modelID ?? "",
                                              usage: CanonicalUsage(inputTokens: 14, outputTokens: 1))
                },
                log: { level, message in logs.mutate { $0.append("\(level.rawValue): \(message)") } })
        }

        func refresh(_ monitor: UsageMonitor, at now: Date) async {
            await monitor.refresh(now: now)
            await monitor.settleWarmUps()
        }

        test("the session window is the account's own, shortest window under a day") {
            let codex = ChatGPTCodexAdapter.parsePlanUsage(try expectNotNil(JSONValue.parse("""
            {"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000},
                           "secondary_window":{"used_percent":12,"limit_window_seconds":604800}},
             "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
                "primary_window":{"used_percent":0,"limit_window_seconds":3600}}}]}
            """)))
            try expectEqual(PlanWarmUp.sessionWindow(codex)?.id, "codex.primary_window",
                            "a model's own shorter window is not the account's")
            try expectEqual(codex.windows.first { $0.id.hasPrefix("extra.") }?.scope, "Spark")

            let claude = ClaudePlanUsage.parse(try expectNotNil(JSONValue.parse("""
            {"five_hour":{"utilization":0.0,"resets_at":null},
             "seven_day":{"utilization":20.0,"resets_at":"2026-09-21T19:59:59Z"},
             "seven_day_opus":{"utilization":0.0,"resets_at":null}}
            """)))
            try expectEqual(PlanWarmUp.sessionWindow(claude)?.id, "five_hour")
            try expectEqual(claude.windows.first { $0.id == "seven_day.opus" }?.scope, "opus")

            let weeklyOnly = ChatGPTCodexAdapter.parsePlanUsage(try expectNotNil(JSONValue.parse("""
            {"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800}}}
            """)))
            try expectNil(PlanWarmUp.sessionWindow(weeklyOnly), "nothing to keep running")

            var limits = RateLimitConfig()
            limits.planRequestsPer5Hours = 100
            let counted = try expectNotNil(ProviderUsage.counted(tallies: [:], limits: limits))
            try expectNil(PlanWarmUp.sessionWindow(counted), "Derby's own count cannot see the provider's clock")
        }

        test("idle means the clock is not running, not that nothing is used") {
            func idle(_ used: Double, _ resets: Date?) -> Bool {
                PlanWarmUp.isIdle(try! expectNotNil(PlanWarmUp.sessionWindow(meter(used, resets: resets, at: t0))),
                                  observedAt: t0)
            }
            try expect(idle(0, nil), "no reset: nothing started")
            try expect(idle(0, t0.addingTimeInterval(-60)), "a reset already passed")
            try expect(idle(0, t0.addingTimeInterval(fiveHours)), "a reset a full window away moves with the clock")
            try expect(!idle(0, t0.addingTimeInterval(fiveHours - 120)), "a warm-up two minutes ago reads 0% and runs")
            try expect(!idle(0, t0.addingTimeInterval(2 * 3600)))
            try expect(!idle(0.03, nil), "anything used means something started it")

            let usage = meter(0, resets: nil, at: t0)
            try expect(PlanWarmUp.shouldWarm(usage, lastWarmedAt: nil, now: t0))
            try expect(!PlanWarmUp.shouldWarm(usage, lastWarmedAt: t0.addingTimeInterval(-3600), now: t0),
                       "the window Derby started an hour ago still runs, whatever the meter says")
            try expect(PlanWarmUp.shouldWarm(usage, lastWarmedAt: t0.addingTimeInterval(-fiveHours), now: t0))
            try expect(!PlanWarmUp.shouldWarm(meter(0, resets: nil, at: t0, weekly: 1), lastWarmedAt: nil, now: t0),
                       "no point starting a window the weekly limit will refuse")

            let request = PlanWarmUp.request(modelID: "lead")
            try expectEqual(request.maxOutputTokens, 16)
            try expectNil(request.reasoning)
            try expectNil(request.temperature, "a background request sends nothing a model might reject")
        }

        test("an idle window is started once, and not again while the window it started runs") {
            let account = claude("Claude", kind: .anthropicSubscription)
            let reading = Locked<ProviderUsage?>(meter(0, resets: nil, at: t0))
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let monitor = monitor([account], reading: reading, sent: sent, logs: logs)

            await refresh(monitor, at: t0)
            try expectEqual(sent.value, ["Claude"])
            try expectEqual(await monitor.snapshot()[account.id]?.warmedAt, t0)
            try expect(logs.value.contains { $0.hasPrefix("info: Started the 5-hour window") && $0.contains("lead") })

            // The next tick checks it: running now.
            let verify = t0.addingTimeInterval(UsageMonitor.tickInterval)
            reading.value = meter(0, resets: t0.addingTimeInterval(fiveHours), at: verify)
            await refresh(monitor, at: verify)
            // A meter that reads idle again later changes nothing while it runs.
            let later = verify.addingTimeInterval(UsageMonitor.pollInterval)
            reading.value = meter(0, resets: nil, at: later)
            await refresh(monitor, at: later)
            try expectEqual(sent.value.count, 1)
            try expect(!logs.value.contains { $0.hasPrefix("warn") }, "\(logs.value)")

            // Once it has run its course, the next one starts.
            let next = t0.addingTimeInterval(fiveHours + 1)
            reading.value = meter(0, resets: t0.addingTimeInterval(fiveHours), at: next)
            await refresh(monitor, at: next)
            try expectEqual(sent.value.count, 2)
        }

        test("a window that resets is started again within a tick, not at the next poll") {
            let account = claude("Claude", kind: .anthropicSubscription)
            let resets = t0.addingTimeInterval(100)
            let reading = Locked<ProviderUsage?>(meter(0.4, resets: resets, at: t0))
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let monitor = monitor([account], reading: reading, sent: sent, logs: logs)
            await refresh(monitor, at: t0)
            try expectEqual(sent.value, [], "a running window is left alone")

            let tick = t0.addingTimeInterval(2 * UsageMonitor.tickInterval)
            reading.value = meter(0, resets: nil, at: tick)
            await refresh(monitor, at: tick)
            try expectEqual(sent.value, ["Claude"])
        }

        test("one account saying no stops the whole login") {
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let accounts = [claude("Claude direct", kind: .anthropicSubscription),
                            claude("Claude Code", kind: .claudeCodeCLI, keep: false)]
            let monitor = monitor(accounts, reading: Locked(meter(0, resets: nil, at: t0)), sent: sent, logs: logs)
            await refresh(monitor, at: t0)
            try expectEqual(sent.value, [])
            try expect(!UsageMonitor.keepsWarm(accounts))
            try expect(UsageMonitor.keepsWarm([accounts[0]]), "unset means on")
        }

        test("a login sends one warm-up, and one that does not start the window hands over") {
            let direct = claude("Claude direct", kind: .anthropicSubscription)
            let cli = claude("Claude Code", kind: .claudeCodeCLI)
            let reading = Locked<ProviderUsage?>(meter(0, resets: nil, at: t0))
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let monitor = monitor([direct, cli], reading: reading, sent: sent, logs: logs)

            await refresh(monitor, at: t0)
            try expectEqual(sent.value, ["Claude direct"], "one login, one request")

            // It answered but landed outside the plan: still idle a tick later.
            let verify = t0.addingTimeInterval(UsageMonitor.tickInterval)
            reading.value = meter(0, resets: nil, at: verify)
            await refresh(monitor, at: verify)
            try expectEqual(sent.value, ["Claude direct", "Claude Code"])
            try expect(logs.value.contains { $0.hasPrefix("warn") && $0.contains("trying Claude Code") })
            try expectEqual(await monitor.snapshot()[cli.id]?.warmedAt, verify,
                            "credited to the request that started it, not the one that did nothing")

            let confirm = verify.addingTimeInterval(UsageMonitor.tickInterval)
            reading.value = meter(0, resets: verify.addingTimeInterval(fiveHours), at: confirm)
            await refresh(monitor, at: confirm)
            try expectEqual(sent.value.count, 2)
            try expectEqual(await monitor.snapshot()[direct.id]?.warmedAt, verify, "shared by the login")

            // The account that worked goes first next time.
            let next = verify.addingTimeInterval(fiveHours + 1)
            reading.value = meter(0, resets: verify.addingTimeInterval(fiveHours), at: next)
            await refresh(monitor, at: next)
            try expectEqual(sent.value.last, "Claude Code")
        }

        test("when no account starts the window, Derby says so once and waits it out") {
            let account = claude("Claude", kind: .anthropicSubscription)
            let reading = Locked<ProviderUsage?>(meter(0, resets: nil, at: t0))
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let monitor = monitor([account], reading: reading, sent: sent, logs: logs)
            await refresh(monitor, at: t0)
            for step in 1...4 {
                let now = t0.addingTimeInterval(Double(step) * UsageMonitor.pollInterval / 4 + 1)
                reading.value = meter(0, resets: nil, at: now)
                await refresh(monitor, at: now)
            }
            try expectEqual(sent.value.count, 1)
            try expectEqual(logs.value.filter { $0.contains("did not start") }.count, 1, "\(logs.value)")
            try expectNil(await monitor.snapshot()[account.id]?.warmedAt)

            let next = t0.addingTimeInterval(fiveHours + 1)
            reading.value = meter(0, resets: nil, at: next)
            await refresh(monitor, at: next)
            try expectEqual(sent.value.count, 2, "a new round once the window would have ended")
        }

        test("a failed warm-up is retried at the next poll and logged once") {
            let account = claude("Claude", kind: .anthropicSubscription)
            let reading = Locked<ProviderUsage?>(meter(0, resets: nil, at: t0))
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let failure = Locked<DerbyError?>(DerbyError(kind: .authentication, message: "not signed in"))
            let monitor = monitor([account], reading: reading, sent: sent, logs: logs, failure: failure)
            await refresh(monitor, at: t0)
            await refresh(monitor, at: t0.addingTimeInterval(UsageMonitor.tickInterval))
            try expectEqual(sent.value.count, 1, "a failure does not make the meter due at the next tick")
            let poll = t0.addingTimeInterval(UsageMonitor.pollInterval)
            reading.value = meter(0, resets: nil, at: poll)
            await refresh(monitor, at: poll)
            try expectEqual(sent.value.count, 2)
            try expectEqual(logs.value.filter { $0.contains("not signed in") }.count, 1)
            try expectContains(try expectNotNil(await monitor.snapshot()[account.id]?.warmError), "not signed in")
        }

        test("nothing is started while paused, from Derby's own count, or when the plan is spent") {
            let sent = Locked<[String]>([]), logs = Locked<[String]>([])
            let paused = monitor([claude("Claude", kind: .anthropicSubscription)],
                                 reading: Locked(meter(0, resets: nil, at: t0)), sent: sent, logs: logs)
            await paused.setWarmingSuspended(true)
            await refresh(paused, at: t0)

            let spent = monitor([claude("Claude", kind: .anthropicSubscription)],
                                reading: Locked(meter(0, resets: nil, at: t0, weekly: 1)), sent: sent, logs: logs)
            await refresh(spent, at: t0)

            var limits = RateLimitConfig()
            limits.planRequestsPer5Hours = 100
            let qwen = ProviderAccount(name: "Qwen Cloud", kind: .qwen, auth: .apiKey(SecretRef(account: "q")),
                                       rateLimits: limits, models: [PhysicalModel(modelID: "qwen")])
            let counted = monitor([qwen], reading: Locked(nil), sent: sent, logs: logs)
            await refresh(counted, at: t0)
            try expectEqual(await counted.snapshot()[qwen.id]?.usage?.source, .counted)

            try expectEqual(sent.value, [])
        }

        test("the engine sends a warm-up straight through the adapter, without prompting") {
            let adapter = WarmUpRecorder()
            let account = ProviderAccount(name: "ChatGPT", kind: .chatgptSubscription,
                                          auth: .cli(source: .codexCLI, allowRefresh: false),
                                          models: [PhysicalModel(modelID: "gpt-lead"),
                                                   PhysicalModel(modelID: "gpt-side")])
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-warm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
            try store.save(DerbyConfig(providers: [account], logicalModels: []))
            let telemetry = TelemetryStore(path: dir.appendingPathComponent("t.sqlite3").path)
            try await telemetry.open()
            let engine = DerbyEngine(configStore: store, secrets: InMemorySecretStore(), transport: MockTransport(),
                                     adapters: AdapterRegistry.default.overriding(.chatgptCodex, with: adapter),
                                     telemetry: telemetry)
            let start = Date()

            await engine.setRoutingPaused(true)
            await engine.usageMonitor.refresh(now: start)
            await engine.usageMonitor.settleWarmUps()
            try expectEqual(adapter.sent.count, 0, "paused means nothing is sent")

            await engine.setRoutingPaused(false)
            await engine.usageMonitor.refresh(now: start.addingTimeInterval(UsageMonitor.pollInterval))
            await engine.usageMonitor.settleWarmUps()
            let sent = try expectNotNil(adapter.sent.first)
            try expectEqual(sent.model, "gpt-lead", "the account's first model")
            try expectEqual(sent.request.maxOutputTokens, 16)
            try expect(!sent.mayPrompt, "background work never opens the Keychain")
            try expectEqual(await telemetry.requestTallies(since: start.addingTimeInterval(-60)).count, 0,
                            "a warm-up is not a routed request")
            await telemetry.close()
        }
    }
}

/// A value several closures in a test share.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}

/// A subscription whose meter always reads idle, recording each warm-up.
final class WarmUpRecorder: ProviderAdapter, @unchecked Sendable {
    let family: AdapterFamily = .chatgptCodex
    private let lock = NSLock()
    private var _sent: [(model: String, request: CanonicalRequest, mayPrompt: Bool)] = []
    var sent: [(model: String, request: CanonicalRequest, mayPrompt: Bool)] {
        lock.lock(); defer { lock.unlock() }; return _sent
    }

    func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth { ResolvedAuth() }
    func usage(_ ctx: ProviderContext) async throws -> ProviderUsage? {
        ProviderUsage(windows: [.init(id: "codex.primary_window", label: "5-hour", usedFraction: 0,
                                      duration: ProviderUsage.fiveHours)])
    }
    func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        lock.withLock { _sent.append((model, request, ctx.mayPromptForCredentials)) }
        return CanonicalResponse(id: "warm", model: model, message: .assistant("ok"),
                                 usage: CanonicalUsage(inputTokens: 12, outputTokens: 1))
    }
    func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        throw DerbyError(kind: .transient, message: "not streamed")
    }
    func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        DerbyError(kind: .transient, message: "mock", providerStatus: status)
    }
}
