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

        test("a growing tool loop keeps every earlier byte, under one session") {
            // What a tool loop actually sends: not the same request again, but
            // the one before it with a call and its result on the end.
            let account = try codexAccount()
            let transport = backend()
            for steps in 1...6 {
                let json = try expectNotNil(JSONValue.parse(HermesLoop.request(steps: steps)))
                try await send(try OpenAIRequestParser.parseChatCompletions(json), on: account, via: transport)
            }
            try expectGrowsAtTheEnd(transport, history: "input")
            try expectEqual(Set(transport.requests.compactMap { $0.headers["session_id"] }).count, 1)
            try expectEqual(Set(transport.requests.compactMap { $0.body?["prompt_cache_key"]?.stringValue }).count, 1)
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

    // MARK: - OpenAI-compatible servers

    /// A vLLM or llama.cpp server finds its cache by the prompt alone: no key and
    /// no session, only the tokens of the prompt matched from the start. Its chat
    /// template renders tool schemas and messages in the key order the JSON
    /// arrived in, so a reordered key is a different prompt. Before this, Qwen on
    /// vLLM re-read 35–41K tokens on every step of a Hermes loop, and in its whole
    /// history never served more than 1,600 from its cache.

    func compatibleServer(_ kind: ProviderKind) -> ProviderAccount {
        Fixture.account("enzotide", kind: kind,
                        models: [Fixture.model("Qwen3.8-27B", caps: [.text, .streaming, .tools, .reasoning])])
    }

    func compatibleBackend(_ answer: [String] = HermesLoop.answer(step: 0)) -> MockTransport {
        let transport = MockTransport()
        transport.stubStream("/v1/chat/completions", events: answer)
        transport.stub("/v1/chat/completions", json: HermesLoop.completion)
        return transport
    }

    /// One request exactly as the gateway handles it: parsed from what the
    /// client sent, so every dictionary in it is new.
    func sendChat(_ client: String, streaming: Bool, on account: ProviderAccount,
                  via transport: MockTransport) async throws -> [CanonicalUsage] {
        let request = try OpenAIRequestParser.parseChatCompletions(try expectNotNil(JSONValue.parse(client)))
        let ctx = ProviderContext(account: account, transport: transport, secrets: InMemorySecretStore(),
                                  credentials: CredentialCache(), attemptTimeout: 5)
        guard streaming else {
            return [try await OpenAIAdapter().execute(request, model: "Qwen3.8-27B", ctx: ctx).usage]
        }
        var usage: [CanonicalUsage] = []
        for try await event in try await OpenAIAdapter().stream(request, model: "Qwen3.8-27B", ctx: ctx) {
            if case .usage(let u) = event { usage.append(u) }
        }
        return usage
    }

    suite("Prompt cache / OpenAI-compatible") {
        test("the same tool-loop request is sent as the same bytes every time") {
            let client = HermesLoop.request(steps: 2)
            for kind in [ProviderKind.vllm, .llamaCpp] {
                for streaming in [true, false] {
                    let account = compatibleServer(kind)
                    let transport = compatibleBackend()
                    for _ in 0..<100 {
                        let usage = try await sendChat(client, streaming: streaming, on: account, via: transport)
                        try expectEqual(usage.map(\.cachedInputTokens), [40_000], "the server's cache report reaches Derby")
                    }
                    let path = "\(kind.rawValue), \(streaming ? "streaming" : "not streaming")"
                    try expectEqual(Set(transport.requests.compactMap(\.rawBody)).count, 1,
                                    "\(path): any difference moves the start of the prompt, and nothing after it is cached")

                    // Only the order of keys may change. Arrays are the client's.
                    let sent = try expectNotNil(transport.requests.first?.body)
                    let parsed = try OpenAIRequestParser.parseChatCompletions(try expectNotNil(JSONValue.parse(client)))
                    try expectEqual(sent, try OpenAIAdapter().buildChatBody(
                        parsed, model: "Qwen3.8-27B", quirks: OpenAIQuirks.forKind(kind, account: account),
                        stream: streaming), "\(path): the same request, whatever order it is written in")
                    try expectEqual(sent["tools"]?.arrayValue?.compactMap { $0["function"]?["name"]?.stringValue },
                                    HermesLoop.toolNames)
                    try expectEqual(sent["tools"]?[1]?["function"]?["parameters"]?["required"]?.arrayValue?
                                        .compactMap(\.stringValue), ["query", "folders"])
                    try expectEqual(sent["messages"]?.arrayValue?.compactMap { $0["role"]?.stringValue },
                                    ["system", "user", "assistant", "tool", "assistant", "tool"])
                }
            }
        }

        test("a growing tool loop keeps every earlier byte of its prompt") {
            let account = compatibleServer(.vllm)
            let transport = compatibleBackend()
            for steps in 1...6 {
                _ = try await sendChat(HermesLoop.request(steps: steps), streaming: true, on: account, via: transport)
            }
            try expectGrowsAtTheEnd(transport, history: "messages")
        }

        test("reasoning the ledger puts back reaches the server the same way on every step") {
            // Hermes keeps no reasoning, so each step goes back without it and
            // the ledger restores it. Restored text is part of the prompt the
            // template renders, so it must come back identically every time.
            let account = compatibleServer(.vllm)
            let config = Fixture.config(accounts: [account], logicalModels: [Fixture.logical("qwen", accounts: [account])])
            let transport = compatibleBackend()
            let executor = Executor(registry: .default, transport: transport, secrets: InMemorySecretStore(),
                                    credentials: CredentialCache(), health: HealthRegistry(settings: config.health),
                                    telemetry: RecordingSink())
            var callIDs: [String] = []
            for steps in 0...4 {
                let parsed = try OpenAIRequestParser.parseChatCompletions(try expectNotNil(JSONValue.parse(
                    HermesLoop.request(steps: steps, reasoningSentBack: false, callIDs: callIDs))))
                let request = await executor.ledger.annotate(parsed)
                transport.stubStream("/v1/chat/completions", events: HermesLoop.answer(step: steps))
                let decision = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
                for try await event in executor.stream(request, decision: decision, meta: RequestMeta()) {
                    // The client calls back with the id Derby gave it, which is
                    // not always the one the server used.
                    if case .canonical(.toolCallStart(_, let id, _)) = event { callIDs.append(id) }
                }
            }

            let assistants = try expectNotNil(transport.requests.last?.body?["messages"]?.arrayValue)
                .filter { $0["role"]?.stringValue == "assistant" }
            try expectEqual(assistants.map { $0["reasoning_content"]?.stringValue },
                            (0..<4).map { Optional(HermesLoop.reasoning(step: $0)) },
                            "the ledger restored what the client dropped")
            try expectGrowsAtTheEnd(transport, history: "messages")
        }

        test("a cache hit the server reports reaches the history and the client") {
            let account = compatibleServer(.vllm)
            let config = Fixture.config(accounts: [account], logicalModels: [Fixture.logical("qwen", accounts: [account])])
            let executor = Executor(registry: .default, transport: compatibleBackend(), secrets: InMemorySecretStore(),
                                    credentials: CredentialCache(), health: HealthRegistry(settings: config.health),
                                    telemetry: RecordingSink())
            let request = try OpenAIRequestParser.parseChatCompletions(try expectNotNil(JSONValue.parse(
                HermesLoop.request(steps: 1))))
            let decision = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            var finished: RequestRecord?
            for try await event in executor.stream(request, decision: decision, meta: RequestMeta()) {
                if case .finished(let r) = event { finished = r }
            }
            let record = try expectNotNil(finished)
            try expectEqual(record.usage.cachedInputTokens, 40_000)
            try expect(!record.usage.isEstimated, "reported by the server, not made up by Derby")

            let chunk = OpenAIResponseWriter.ChatChunkEmitter(requestID: record.id, model: "qwen")
                .usageChunk(record.usage, record: record)
            try expectEqual(chunk["usage"]?["prompt_tokens_details"]?["cached_tokens"]?.intValue, 40_000)

            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-cache-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = TelemetryStore(path: directory.appendingPathComponent("t.sqlite3").path,
                                       settings: LoggingSettings(level: .debug))
            try await store.open()
            await store.record(record)
            try expectEqual(await store.request(id: record.id)?.usage.cachedInputTokens, 40_000)
            try expectEqual(await store.usage(window: .today).cachedTokens, 40_000, "the cached_tokens column")
            await store.close()
        }
    }
}

// MARK: - Fixtures

/// What a Hermes tool loop sends on every step: the same instructions and
/// tools, and a history that only ever grows at the end. Written as the text a
/// client sends, so no part of it is a dictionary until Derby parses it.
enum HermesLoop {
    static let toolNames = ["read_file", "search_email", "write_canvas", "terminal", "browser_navigate", "memory"]

    static let tools = #"""
    [{"type":"function","function":{"name":"read_file","description":"Read a file from the workspace.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the workspace root."},"offset":{"type":"integer","default":0},"limit":{"type":"integer","default":2000}},"required":["path","limit"],"additionalProperties":false}}},
    {"type":"function","function":{"name":"search_email","description":"Search the mailbox.","parameters":{"type":"object","properties":{"query":{"type":"string"},"folders":{"type":"array","items":{"type":"string","enum":["inbox","archive","spam"]}},"filters":{"type":"object","properties":{"from":{"type":"string"},"since":{"type":"string","format":"date"},"unread":{"type":"boolean","default":true}},"additionalProperties":false}},"required":["query","folders"]}}},
    {"type":"function","function":{"name":"write_canvas","description":"Replace a section of the canvas.","parameters":{"type":"object","properties":{"section":{"type":"string","enum":["triage","todo","notes"]},"markdown":{"type":"string"},"mode":{"type":"string","enum":["replace","append"],"default":"append"}},"required":["section","markdown"]}}},
    {"type":"function","function":{"name":"terminal","description":"Run a shell command.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"number","default":120},"env":{"type":"object","additionalProperties":{"type":"string"}},"background":{"type":"boolean"}},"required":["command"]}}},
    {"type":"function","function":{"name":"browser_navigate","description":"Open a page.","parameters":{"type":"object","properties":{"url":{"type":"string","format":"uri"},"wait":{"type":"object","properties":{"selector":{"type":"string"},"seconds":{"type":"number"}}}},"required":["url"]}}},
    {"type":"function","function":{"name":"memory","description":"Save or recall a fact.","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["save","recall","forget"]},"key":{"type":"string"},"value":{"type":"string"},"tags":{"type":"array","items":{"type":"string"},"maxItems":8}},"required":["action","key"]}}}]
    """#

    static func reasoning(step: Int) -> String { "Step \(step): look at the triage file before changing it." }

    /// The request for a loop that has taken `steps` tool calls so far.
    static func request(steps: Int, reasoningSentBack: Bool = true, callIDs: [String] = []) -> String {
        var messages = [
            #"{"role":"system","content":"You are Hermes. You triage email and keep the canvas current. Use tools; never guess."}"#,
            #"{"role":"user","content":"Add to the canvas email triage that all the generic Canvas emails are a summary."}"#,
        ]
        for step in 0..<steps {
            let id = step < callIDs.count ? callIDs[step] : "call_\(step)"
            let reasoning = reasoningSentBack ? #","reasoning_content":"\#(Self.reasoning(step: step))""# : ""
            messages.append(#"{"role":"assistant","content":null\#(reasoning),"tool_calls":[{"id":"\#(id)","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"canvas/triage-\#(step).md\",\"limit\":200}"}}]}"#)
            messages.append(#"{"role":"tool","tool_call_id":"\#(id)","content":"Triage \#(step):\n- generic Canvas emails: summary only"}"#)
        }
        return #"{"model":"qwen","stream":true,"reasoning_effort":"high","messages":["#
            + messages.joined(separator: ",") + #"],"tools":"# + tools + "}"
    }

    /// The server's streamed answer to step `step`: its reasoning, the next
    /// call, and a usage report that says most of the prompt was cached.
    static func answer(step: Int) -> [String] {
        [
            #"{"id":"chatcmpl-\#(step)","model":"Qwen3.8-27B","choices":[{"index":0,"delta":{"reasoning_content":"\#(reasoning(step: step))"}}]}"#,
            #"{"id":"chatcmpl-\#(step)","model":"Qwen3.8-27B","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_\#(step)","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"canvas/triage-\#(step).md\",\"limit\":200}"}}]}}]}"#,
            #"{"id":"chatcmpl-\#(step)","model":"Qwen3.8-27B","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"id":"chatcmpl-\#(step)","model":"Qwen3.8-27B","choices":[],"usage":{"prompt_tokens":41422,"completion_tokens":336,"prompt_tokens_details":{"cached_tokens":40000}}}"#,
        ]
    }

    static let completion = #"""
    {"id":"chatcmpl-0","model":"Qwen3.8-27B","choices":[{"index":0,"message":{"role":"assistant","content":"Done."},"finish_reason":"stop"}],
     "usage":{"prompt_tokens":41422,"completion_tokens":336,"prompt_tokens_details":{"cached_tokens":40000}}}
    """#
}

/// Asserts that each request a loop sent is the one before it plus what is
/// new: the history array starts with every byte the previous one had, and
/// every other field (tools, instructions, settings) is byte-identical.
func expectGrowsAtTheEnd(_ transport: MockTransport, history: String,
                         file: String = #fileID, line: Int = #line) throws {
    let bodies = transport.requests.compactMap(\.rawBody)
    try expect(bodies.count > 1, "a loop needs more than one request", file: file, line: line)
    let fields = transport.requests.first?.body?.objectValue?.keys.filter { $0 != history } ?? []
    try expect(fields.contains("tools"), "the tools are what a template renders first", file: file, line: line)
    for field in fields {
        let sent = Set(bodies.map { sentBytes(of: field, in: $0) })
        try expectEqual(sent.count, 1, "\"\(field)\" changed between steps of one loop", file: file, line: line)
    }
    let histories = try bodies.map { try expectNotNil(sentBytes(of: history, in: $0), file: file, line: line) }
    for (step, (earlier, later)) in zip(histories, histories.dropFirst()).enumerated() {
        let kept = earlier.dropLast()   // all but the closing bracket
        try expect(later.count > earlier.count && later.starts(with: kept)
                       && later[later.startIndex + kept.count] == UInt8(ascii: ","),
                   "step \(step + 1) rewrote history the server had already read", file: file, line: line)
    }
}

/// The bytes one top-level field's value was sent as.
///
/// Decoding would hand back a dictionary and discard the very key order under
/// test, so the body is walked as bytes: strings are skipped whole, escapes
/// included, and nesting is counted, which is all a well-formed body needs.
func sentBytes(of field: String, in body: Data) -> Data? {
    let b = [UInt8](body)
    let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
    func endOfString(_ start: Int) -> Int {
        var i = start + 1
        while i < b.count, b[i] != quote { i += b[i] == backslash ? 2 : 1 }
        return i + 1
    }
    func endOfValue(_ start: Int) -> Int {
        var i = start, depth = 0
        while i < b.count {
            switch b[i] {
            case quote:
                i = endOfString(i)
                if depth == 0 { return i }
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 { return i }
                depth -= 1
                if depth == 0 { return i + 1 }
            case UInt8(ascii: ","):
                if depth == 0 { return i }
            default:
                break
            }
            i += 1
        }
        return i
    }
    guard b.first == UInt8(ascii: "{") else { return nil }
    var i = 1
    while i < b.count {
        guard b[i] == quote else { i += 1; continue }
        let keyEnd = endOfString(i)
        let key = String(decoding: b[(i + 1)..<(keyEnd - 1)], as: UTF8.self)
        var valueStart = keyEnd
        while valueStart < b.count, b[valueStart] != UInt8(ascii: ":") { valueStart += 1 }
        valueStart += 1
        let valueEnd = endOfValue(valueStart)
        if key == field { return Data(b[valueStart..<valueEnd]) }
        i = valueEnd
    }
    return nil
}
