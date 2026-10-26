import Foundation
@testable import DerbyCore

/// A Claude subscription reaching the Messages API as Claude Code would, and
/// never billed past its plan.
func registerClaudePlanTests() {

    /// A Claude login in its own throwaway credential home, which reads only
    /// its own file and never the Keychain.
    func claudeLogin() throws -> ProviderAccount {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let expiry = (Date().timeIntervalSince1970 + 3600) * 1000
        try Data(#"{"claudeAiOauth":{"accessToken":"tok-test","expiresAt":\#(expiry)}}"#.utf8)
            .write(to: home.appendingPathComponent(".credentials.json"))
        return ProviderAccount(name: "Claude", kind: .anthropicSubscription,
                               auth: .cli(source: .claudeCode, allowRefresh: false),
                               models: [Fixture.model("claude-opus-5")],
                               credentialHomeOverride: home.path)
    }

    func ctx(_ account: ProviderAccount, _ transport: MockTransport) -> ProviderContext {
        ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                        credentials: CredentialCache(), attemptTimeout: 5)
    }

    let future = String(Int(Date().timeIntervalSince1970 + 4 * 3600))
    let onPlan = ["anthropic-ratelimit-unified-status": "allowed",
                  "anthropic-ratelimit-unified-5h-utilization": "0.12",
                  "anthropic-ratelimit-unified-overage-status": "rejected"]
    let onExtraUsage = ["anthropic-ratelimit-unified-status": "rejected",
                        "anthropic-ratelimit-unified-overage-status": "allowed",
                        "anthropic-ratelimit-unified-reset": future]
    let toolStream = [
        #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":0}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu1","name":"mcp__read_file"}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}"#,
        #"{"type":"message_stop"}"#,
    ]
    func toolRequest() -> CanonicalRequest {
        var r = CanonicalRequest(requestedModel: "planclaude")
        r.messages = [.system("You are Hermes Agent, made by Nous Research."), .user("Is Hermes Agent good?")]
        r.tools = [CanonicalTool(name: "read_file"), CanonicalTool(name: "mcp_linear_get_issue")]
        r.stream = true
        return r
    }

    suite("Claude subscription / tool names") {
        test("every tool goes out as an mcp__ name and comes back as the client's") {
            let names = ClaudeCodeIdentity.ToolNames(["read_file", "mcp_linear_get_issue", "mcp__a__b"])
            try expectEqual(names.wire("read_file"), "mcp__read_file")
            try expectEqual(names.wire("mcp_linear_get_issue"), "mcp__linear_get_issue",
                            "a single-underscore mcp_ name is the third-party fingerprint itself")
            try expectEqual(names.wire("mcp__a__b"), "mcp__a__b")
            for name in ["read_file", "mcp_linear_get_issue", "mcp__a__b"] {
                try expectEqual(names.client(names.wire(name)), name)
            }
            try expectEqual(names.client("mcp__never_offered"), "never_offered")
            try expectEqual(ClaudeCodeIdentity.ToolNames.unchanged.wire("read_file"), "read_file")
        }

        test("names that land on one wire name stay distinct, and long ones fit the limit") {
            let names = ClaudeCodeIdentity.ToolNames(["read_file", "mcp_read_file", "mcp__read_file"])
            let wires = ["read_file", "mcp_read_file", "mcp__read_file"].map(names.wire)
            try expectEqual(Set(wires).count, 3)
            for name in ["read_file", "mcp_read_file", "mcp__read_file"] {
                try expectEqual(names.client(names.wire(name)), name)
            }
            let long = String(repeating: "x", count: 70)
            let longer = long + "y"
            let fitted = ClaudeCodeIdentity.ToolNames([long, longer])
            try expect(fitted.wire(long).count <= 64 && fitted.wire(longer).count <= 64)
            try expect(fitted.wire(long) != fitted.wire(longer))
            try expectEqual(fitted.wire(long), ClaudeCodeIdentity.ToolNames([long]).wire(long),
                            "the same name must go out the same way every turn, or the prompt cache misses")
            try expectEqual(fitted.client(fitted.wire(longer)), longer)
        }

        test("the subscription body renames tools, history and tool_choice; an API key does not") {
            var r = toolRequest()
            r.messages += [CanonicalMessage(role: .assistant,
                                            toolCalls: [CanonicalToolCall(id: "t1", name: "read_file", argumentsJSON: "{}")]),
                           CanonicalMessage(role: .tool, content: [.text("ok")], toolCallID: "t1")]
            r.toolChoice = .function("read_file")
            let account = try claudeLogin()
            let body = try AnthropicAdapter(oauth: true).buildBody(r, model: "claude-opus-5",
                                                                   ctx: ctx(account, MockTransport()), stream: false)
            try expectEqual(body["tools"]?[0]?["name"]?.stringValue, "mcp__read_file")
            try expectEqual(body["tools"]?[1]?["name"]?.stringValue, "mcp__linear_get_issue")
            try expectEqual(body["messages"]?[1]?["content"]?[0]?["name"]?.stringValue, "mcp__read_file")
            try expectEqual(body["tool_choice"]?["name"]?.stringValue, "mcp__read_file")

            let keyed = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-opus-5")])
            let plain = try AnthropicAdapter(oauth: false).buildBody(r, model: "claude-opus-5",
                                                                     ctx: ctx(keyed, MockTransport()), stream: false)
            try expectEqual(plain["tools"]?[0]?["name"]?.stringValue, "read_file")
        }

        test("a reply's tool calls reach the client under its own names") {
            let r = toolRequest()
            let adapter = AnthropicAdapter(oauth: true)
            let json = try expectNotNil(JSONValue.parse(#"{"id":"m","model":"claude-opus-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"mcp__linear_get_issue","input":{}}]}"#))
            let parsed = try adapter.parseResponse(json, fallbackModel: "x", toolNames: adapter.toolNames(for: r))
            try expectEqual(parsed.message.toolCalls.first?.name, "mcp_linear_get_issue")
        }
    }

    suite("Claude subscription / prompt rewrites") {
        test("the default pairs rewrite the system prompt and nothing else") {
            let body = try AnthropicAdapter(oauth: true).buildBody(toolRequest(), model: "claude-opus-5",
                                                                   ctx: ctx(try claudeLogin(), MockTransport()), stream: false)
            try expectEqual(body["system"]?[0]?["text"]?.stringValue, ClaudeCodeIdentity.systemPrompt)
            try expectEqual(body["system"]?[1]?["text"]?.stringValue, "You are Claude Code, made by Anthropic.")
            try expectEqual(body["messages"]?[0]?["content"]?[0]?["text"]?.stringValue, "Is Hermes Agent good?",
                            "the conversation itself is never rewritten")
        }

        test("an empty list, or an API key, sends the prompt unchanged") {
            var account = try claudeLogin()
            account.promptRewrites = []
            let off = try AnthropicAdapter(oauth: true).buildBody(toolRequest(), model: "claude-opus-5",
                                                                  ctx: ctx(account, MockTransport()), stream: false)
            try expectEqual(off["system"]?[1]?["text"]?.stringValue, "You are Hermes Agent, made by Nous Research.")
            var keyed = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-opus-5")])
            keyed.promptRewrites = [PromptRewrite(find: "Hermes", replace: "X")]
            let plain = try AnthropicAdapter(oauth: false).buildBody(toolRequest(), model: "claude-opus-5",
                                                                     ctx: ctx(keyed, MockTransport()), stream: false)
            try expectEqual(plain["system"]?[0]?["text"]?.stringValue, "You are Hermes Agent, made by Nous Research.")
            try expectEqual(ProviderKind.allCases.filter { !$0.defaultPromptRewrites.isEmpty }, [.anthropicSubscription])
            try expectEqual(ProviderKind.allCases.filter(\.billsExtraUsage), [.anthropicSubscription])
        }

        test("an account saved before these settings decodes with them unset, and an empty list survives") {
            let saved = try JSONEncoder().encode(ProviderAccount(name: "c", kind: .anthropicSubscription))
            let decoded = try JSONDecoder().decode(ProviderAccount.self, from: saved)
            try expectNil(decoded.allowExtraUsage)
            try expectNil(decoded.promptRewrites)
            try expectEqual(decoded.effectivePromptRewrites, ProviderKind.anthropicSubscription.defaultPromptRewrites)
            var off = decoded
            off.promptRewrites = []
            let round = try JSONDecoder().decode(ProviderAccount.self, from: try JSONEncoder().encode(off))
            try expectEqual(round.promptRewrites, [], "off must not decode back to the defaults")
        }
    }

    suite("Claude subscription / plan guard") {
        test("the headers say which allowance paid") {
            try expectEqual(PlanLane.parse(onPlan), .plan(fiveHour: 0.12, sevenDay: nil))
            try expectEqual(PlanLane.parse(["anthropic-ratelimit-unified-status": "allowed",
                                            "anthropic-ratelimit-unified-overage-in-use": "true"]),
                            .extraUsage(resetsAt: nil))
            try expectEqual(PlanLane.parse(onExtraUsage),
                            .extraUsage(resetsAt: Date(timeIntervalSince1970: Double(future)!)))
            try expectEqual(PlanLane.parse(["anthropic-ratelimit-unified-status": "rejected",
                                            "anthropic-ratelimit-unified-overage-status": "rejected"]),
                            .plan(fiveHour: nil, sevenDay: nil), "refused by the plan, so nothing was billed")
            try expectEqual(PlanLane.parse([:]), .unknown)
        }

        test("a stream the plan paid for passes, with tool names restored") {
            await ClaudeCodeVersion.shared.seed("9.9.9")
            let transport = MockTransport()
            transport.stubStream("/v1/messages", events: toolStream)
            transport.streamHeaders = onPlan
            var acc = StreamAccumulator()
            for try await e in try await AnthropicAdapter(oauth: true, planGuard: ClaudePlanGuard())
                .stream(toolRequest(), model: "claude-opus-5", ctx: ctx(try claudeLogin(), transport)) {
                acc.ingest(e)
            }
            try expectEqual(acc.makeResponse(fallbackModel: "x").message.toolCalls.first?.name, "read_file")
        }

        test("a stream billed to extra usage fails before it is read, and the account is held") {
            await ClaudeCodeVersion.shared.seed("9.9.9")
            let transport = MockTransport()
            transport.stubStream("/v1/messages", events: toolStream)
            transport.streamHeaders = onExtraUsage
            let account = try claudeLogin()
            let adapter = AnthropicAdapter(oauth: true, planGuard: ClaudePlanGuard())
            let error = try await expectFailure(.quotaExhausted) {
                _ = try await adapter.stream(toolRequest(), model: "claude-opus-5", ctx: ctx(account, transport))
            }
            try expect((error.retryAfter ?? 0) > 3 * 3600, "held until the plan's window resets")
            try await expectFailure(.quotaExhausted) {
                _ = try await adapter.stream(toolRequest(), model: "claude-opus-5", ctx: ctx(account, transport))
            }
            try expectEqual(transport.requestCount, 1, "a held account must not be sent anything")
        }

        test("a reply with no sign of the plan holds the account; allowing extra usage turns the guard off") {
            await ClaudeCodeVersion.shared.seed("9.9.9")
            let transport = MockTransport()
            transport.stubStream("/v1/messages", events: toolStream)
            try await expectFailure(.quotaExhausted) {
                _ = try await AnthropicAdapter(oauth: true, planGuard: ClaudePlanGuard())
                    .stream(toolRequest(), model: "claude-opus-5", ctx: ctx(try claudeLogin(), transport))
            }
            var allowed = try claudeLogin()
            allowed.allowExtraUsage = true
            transport.streamHeaders = onExtraUsage
            for try await _ in try await AnthropicAdapter(oauth: true, planGuard: ClaudePlanGuard())
                .stream(toolRequest(), model: "claude-opus-5", ctx: ctx(allowed, transport)) {}
        }

        test("a non-streamed answer billed to extra usage is kept, and the next request held") {
            await ClaudeCodeVersion.shared.seed("9.9.9")
            let transport = MockTransport()
            transport.stub("/v1/messages",
                           json: #"{"id":"m","model":"claude-opus-5","content":[{"type":"text","text":"hi"}]}"#,
                           headers: onExtraUsage)
            let account = try claudeLogin()
            let adapter = AnthropicAdapter(oauth: true, planGuard: ClaudePlanGuard())
            var request = toolRequest()
            request.stream = false
            try expectEqual(try await adapter.execute(request, model: "claude-opus-5", ctx: ctx(account, transport))
                .message.joinedText, "hi")
            try await expectFailure(.quotaExhausted) {
                _ = try await adapter.execute(request, model: "claude-opus-5", ctx: ctx(account, transport))
            }
            try expectEqual(transport.requestCount, 1)
        }

        test("the meter says whether extra usage is on") {
            let on = try expectNotNil(JSONValue.parse(#"{"five_hour":{"utilization":10},"extra_usage":{"is_enabled":true,"utilization":0}}"#))
            let off = try expectNotNil(JSONValue.parse(#"{"five_hour":{"utilization":10},"extra_usage":{"is_enabled":false}}"#))
            try expectEqual(ClaudePlanUsage.parse(on).extraUsageEnabled, true)
            try expectEqual(ClaudePlanUsage.parse(off).extraUsageEnabled, false)
            try expectNil(ClaudePlanUsage.parse(try expectNotNil(JSONValue.parse(#"{"five_hour":{"utilization":10}}"#))).extraUsageEnabled)
        }
    }
}
