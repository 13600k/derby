import Foundation
@testable import DerbyCore

/// A conversation reaching the ChatGPT backend as one conversation.
///
/// The backend serves a turn from its prompt cache only when the turn arrives
/// under the same session and cache key as the one before, in bytes that did
/// not change, with the reasoning of every earlier turn still in place. Miss
/// any of those and the whole history is processed again: before these rules,
/// a 55-step tool loop through Derby had 0% of its input cached where the
/// Codex CLI had 94%.
func registerPromptCacheTests() {

    /// A ChatGPT account signed in through its own throwaway Codex home.
    func codexAccount() throws -> ProviderAccount {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"test-token","account_id":"acct-test"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        return ProviderAccount(name: "ChatGPT", kind: .chatgptSubscription,
                               auth: .cli(source: .codexCLI, allowRefresh: false),
                               models: [Fixture.model("gpt-5.6-sol")],
                               credentialHomeOverride: home.path)
    }

    func backend(_ events: [String] = []) -> MockTransport {
        let transport = MockTransport()
        transport.stubStream("/responses", events: [
            #"{"type":"response.created","response":{"id":"resp_1","model":"gpt-5.6-sol"}}"#,
        ] + events + [
            #"{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}"#,
        ])
        return transport
    }

    func send(_ request: CanonicalRequest, on account: ProviderAccount, via transport: MockTransport) async throws {
        let ctx = ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                                  credentials: CredentialCache())
        for try await _ in try await ChatGPTCodexAdapter().stream(request, model: "gpt-5.6-sol", ctx: ctx) {}
    }

    suite("Prompt cache / ChatGPT") {
        test("every turn of a conversation goes out under one session and cache key") {
            let account = try codexAccount()
            let transport = backend()
            var conversation = CanonicalRequest(requestedModel: "smart", messages: [
                .system("You are a coding agent."), .user("Fix the parser."),
            ])
            try await send(conversation, on: account, via: transport)
            conversation.messages += [.assistant("Fixed it."), .user("Now the tests.")]
            try await send(conversation, on: account, via: transport)

            let turns = transport.requests
            let session = try expectNotNil(turns[0].headers["session_id"])
            try expectEqual(turns[1].headers["session_id"], session, "a new session per turn is a cold cache per turn")
            try expectEqual(turns[0].body?["prompt_cache_key"]?.stringValue, session)
            try expectEqual(turns[1].body?["prompt_cache_key"]?.stringValue, session)

            try await send(CanonicalRequest(requestedModel: "smart", messages: [
                .system("You are a coding agent."), .user("Write the docs."),
            ]), on: account, via: transport)
            try expect(transport.requests[2].headers["session_id"] != session, "another conversation is another session")
            try await send(conversation, on: try codexAccount(), via: transport)
            try expect(transport.requests[3].headers["session_id"] != session,
                       "and so is the same conversation on another account")
        }

        test("a client that names its conversation keeps its own cache key") {
            let chat = try OpenAIRequestParser.parseChatCompletions(try expectNotNil(JSONValue.parse(
                #"{"model":"smart","prompt_cache_key":"session-42","messages":[{"role":"user","content":"hi"}]}"#)))
            try expectEqual(chat.promptCacheKey, "session-42")
            try expectNil(chat.unmappedFields["prompt_cache_key"])
            try expectEqual(ChatGPTCodexAdapter().buildBody(chat, model: "gpt-5.6-sol")["prompt_cache_key"]?.stringValue,
                            "session-42")
            let responses = try OpenAIRequestParser.parseResponses(try expectNotNil(JSONValue.parse(
                #"{"model":"smart","prompt_cache_key":"session-42","input":"hi"}"#)))
            try expectEqual(responses.promptCacheKey, "session-42")

            var long = chat
            long.promptCacheKey = String(repeating: "k", count: 100)
            let bounded = try expectNotNil(ChatGPTCodexAdapter().buildBody(long, model: "gpt-5.6-sol")["prompt_cache_key"]?.stringValue)
            try expect(bounded.count <= 64, "sent \(bounded.count) characters")
        }

        test("the same request is sent as the same bytes every time") {
            // A Swift dictionary's order changes between instances, and tool
            // schemas are where it showed: almost every rebuild of one request
            // came out with its schemas reordered.
            let client = #"""
            {"model":"smart","messages":[{"role":"user","content":"go"}],"tools":[
             {"type":"function","function":{"name":"read","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"],"additionalProperties":false}}},
             {"type":"function","function":{"name":"edit","description":"Edit a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","default":false}},"required":["path","old_string","new_string"]}}},
             {"type":"function","function":{"name":"bash","description":"Run a command","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"number"},"env":{"type":"object","properties":{"PATH":{"type":"string"},"HOME":{"type":"string"}}}},"required":["command"]}}}]}
            """#
            let account = try codexAccount()
            let transport = backend()
            for _ in 0..<10 {
                let json = try expectNotNil(JSONValue.parse(client))
                try await send(try OpenAIRequestParser.parseChatCompletions(json), on: account, via: transport)
            }
            try expectEqual(Set(transport.requests.compactMap(\.rawBody)).count, 1,
                            "any difference moves the start of the prompt, and nothing after it is cached")
        }

        test("a new message still carries the reasoning of the turns before it") {
            let account = try codexAccount()
            let config = Fixture.config(accounts: [account], logicalModels: [Fixture.logical("smart", accounts: [account])])
            let transport = backend([
                #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"sealed-turn-1"}}"#,
                #"{"type":"response.output_text.delta","delta":"Fixed it."}"#,
            ])
            let executor = Executor(registry: .default, transport: transport, secrets: InMemorySecretStore(),
                                    credentials: CredentialCache(), health: HealthRegistry(settings: config.health),
                                    telemetry: RecordingSink())
            let first = CanonicalRequest(requestedModel: "smart", messages: [.user("Fix the parser.")])
            _ = try await executor.execute(first, decision: try Router().route(RoutingRequest(first),
                                                                               snapshot: Fixture.snapshot(config)),
                                           meta: RequestMeta())

            // A Chat Completions client sends the answer back without the
            // reasoning its dialect cannot hold, then says something new.
            let second = await executor.ledger.annotate(CanonicalRequest(requestedModel: "smart", messages: [
                .user("Fix the parser."), .assistant("Fixed it."), .user("Now the tests."),
            ]))
            _ = try await executor.execute(second, decision: try Router().route(RoutingRequest(second),
                                                                                snapshot: Fixture.snapshot(config)),
                                           meta: RequestMeta())

            let input = try expectNotNil(transport.requests.last?.body?["input"]?.arrayValue)
            try expectEqual(input.compactMap { $0["type"]?.stringValue }, ["message", "reasoning", "message", "message"])
            try expectEqual(input[1]["encrypted_content"]?.stringValue, "sealed-turn-1")
        }
    }
}
