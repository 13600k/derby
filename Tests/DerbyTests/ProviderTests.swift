import Foundation
@testable import DerbyCore

func registerProviderTests() {
    func ctx(_ account: ProviderAccount, transport: MockTransport,
             secrets: InMemorySecretStore = InMemorySecretStore()) -> ProviderContext {
        ProviderContext(account: account, transport: transport, secrets: secrets,
                        credentials: CredentialCache(), attemptTimeout: 5)
    }

    suite("Providers / OpenAI request shaping") {
        test("builds a standard chat body") {
            let adapter = OpenAIAdapter()
            var r = CanonicalRequest(requestedModel: "logical")
            r.messages = [.system("sys"), .user("hi")]
            r.temperature = 0.5
            r.maxOutputTokens = 100
            r.stop = ["X"]
            let body = try adapter.buildChatBody(r, model: "gpt-test",
                                                 quirks: OpenAIQuirks(), stream: false)
            try expectEqual(body["model"]?.stringValue, "gpt-test")
            try expectEqual(body["messages"]?.arrayValue?.count, 2)
            try expectEqual(body["messages"]?[0]?["content"]?.stringValue, "sys")
            try expectEqual(body["max_tokens"]?.intValue, 100)
            try expectEqual(body["temperature"]?.doubleValue, 0.5)
            try expectEqual(body["stop"]?[0]?.stringValue, "X")
        }

        test("streaming asks for usage when the server supports stream_options") {
            let adapter = OpenAIAdapter()
            var quirks = OpenAIQuirks()
            quirks.supportsStreamOptions = true
            let body = try adapter.buildChatBody(CanonicalRequest(requestedModel: "l"), model: "m",
                                                 quirks: quirks, stream: true)
            try expectEqual(body["stream"]?.boolValue, true)
            try expectEqual(body["stream_options"]?["include_usage"]?.boolValue, true)

            quirks.supportsStreamOptions = false
            let lean = try adapter.buildChatBody(CanonicalRequest(requestedModel: "l"), model: "m",
                                                 quirks: quirks, stream: true)
            try expectNil(lean["stream_options"], "servers that reject the field must not receive it")
        }

        test("reasoning models get max_completion_tokens") {
            let adapter = OpenAIAdapter()
            var quirks = OpenAIQuirks()
            quirks.prefersMaxCompletionTokens = true
            var r = CanonicalRequest(requestedModel: "l")
            r.maxOutputTokens = 500
            let body = try adapter.buildChatBody(r, model: "o3", quirks: quirks, stream: false)
            try expectEqual(body["max_completion_tokens"]?.intValue, 500)
            try expectNil(body["max_tokens"])
        }

        test("multimodal content becomes the array form with a data URI") {
            let adapter = OpenAIAdapter()
            var r = CanonicalRequest(requestedModel: "l")
            r.messages = [CanonicalMessage(role: .user, content: [
                .text("look"), .image(CanonicalImage(base64: "QUJD", mimeType: "image/png", detail: "low")),
            ])]
            let body = try adapter.buildChatBody(r, model: "m", quirks: OpenAIQuirks(), stream: false)
            let parts = try expectNotNil(body["messages"]?[0]?["content"]?.arrayValue)
            try expectEqual(parts.count, 2)
            try expectEqual(parts[1]["type"]?.stringValue, "image_url")
            try expectContains(try expectNotNil(parts[1]["image_url"]?["url"]?.stringValue),
                               "data:image/png;base64,QUJD")
        }

        test("json_schema degrades to json_object on servers that lack it") {
            let adapter = OpenAIAdapter()
            var quirks = OpenAIQuirks()
            quirks.supportsJSONSchema = false
            var r = CanonicalRequest(requestedModel: "l")
            r.responseFormat = .jsonSchema(name: "s", schema: .object(["type": .string("object")]), strict: true)
            let body = try adapter.buildChatBody(r, model: "m", quirks: quirks, stream: false)
            try expectEqual(body["response_format"]?["type"]?.stringValue, "json_object")
        }

        test("provider extensions are merged as an escape hatch") {
            let adapter = OpenAIAdapter()
            var r = CanonicalRequest(requestedModel: "l")
            r.providerExtensions = ["openai": .object(["custom_flag": .bool(true),
                                                       "temperature": .number(0.99)])]
            let body = try adapter.buildChatBody(r, model: "m", quirks: OpenAIQuirks(), stream: false)
            try expectEqual(body["custom_flag"]?.boolValue, true)
            try expectEqual(body["temperature"]?.doubleValue, 0.99, "extensions win over canonical fields")
        }

        test("tool messages round-trip into the OpenAI shape") {
            let adapter = OpenAIAdapter()
            var r = CanonicalRequest(requestedModel: "l")
            r.messages = [
                CanonicalMessage(role: .assistant,
                                 toolCalls: [CanonicalToolCall(id: "c1", name: "f", argumentsJSON: "{\"a\":1}")]),
                CanonicalMessage(role: .tool, content: [.text("42")], toolCallID: "c1"),
            ]
            let body = try adapter.buildChatBody(r, model: "m", quirks: OpenAIQuirks(), stream: false)
            let msgs = try expectNotNil(body["messages"]?.arrayValue)
            try expectEqual(msgs[0]["tool_calls"]?[0]?["function"]?["name"]?.stringValue, "f")
            try expectEqual(msgs[1]["role"]?.stringValue, "tool")
            try expectEqual(msgs[1]["tool_call_id"]?.stringValue, "c1")
        }
    }

    suite("Providers / OpenAI response parsing") {
        test("parses a complete chat completion") {
            let adapter = OpenAIAdapter()
            let json = try expectNotNil(JSONValue.parse("""
            {"id":"chatcmpl-1","model":"gpt-test","created":1700000000,
             "choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],
             "usage":{"prompt_tokens":11,"completion_tokens":3,
                      "prompt_tokens_details":{"cached_tokens":8},
                      "completion_tokens_details":{"reasoning_tokens":2}}}
            """))
            let r = try adapter.parseChatResponse(json, fallbackModel: "fallback")
            try expectEqual(r.model, "gpt-test")
            try expectEqual(r.message.joinedText, "Hello")
            try expectEqual(r.finishReason, .stop)
            try expectEqual(r.usage.inputTokens, 11)
            try expectEqual(r.usage.cachedInputTokens, 8)
            try expectEqual(r.usage.reasoningTokens, 2)
        }

        test("parses tool calls") {
            let adapter = OpenAIAdapter()
            let json = try expectNotNil(JSONValue.parse("""
            {"id":"x","model":"m","choices":[{"message":{"role":"assistant","content":null,
              "tool_calls":[{"id":"call_1","type":"function",
                             "function":{"name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}]},
              "finish_reason":"tool_calls"}]}
            """))
            let r = try adapter.parseChatResponse(json, fallbackModel: "m")
            try expectEqual(r.finishReason, .toolCalls)
            try expectEqual(r.message.toolCalls.count, 1)
            try expectEqual(r.message.toolCalls[0].argumentsValue["city"]?.stringValue, "Paris")
        }

        test("reasoning content is captured under any of its names") {
            let adapter = OpenAIAdapter()
            for key in ["reasoning_content", "reasoning", "thinking"] {
                let json = try expectNotNil(JSONValue.parse("""
                {"id":"x","model":"m","choices":[{"message":{"role":"assistant","content":"a","\(key)":"why"}}]}
                """))
                let r = try adapter.parseChatResponse(json, fallbackModel: "m")
                try expectEqual(r.message.reasoning, "why", "failed for key \(key)")
            }
        }

        test("a response with no choices is a transient failure, not a crash") {
            let adapter = OpenAIAdapter()
            _ = try await expectFailure(.transient) {
                _ = try adapter.parseChatResponse(.object(["id": .string("x")]), fallbackModel: "m")
            }
        }
    }

    suite("Providers / OpenAI error classification") {
        let adapter = OpenAIAdapter()
        func classify(_ status: Int, _ body: String, headers: [String: String] = [:]) -> DerbyError {
            adapter.classifyError(status: status, headers: headers, body: Data(body.utf8), model: "m")
        }

        test("maps status codes and messages to the taxonomy") {
            try expectEqual(classify(401, #"{"error":{"message":"bad key"}}"#).kind, .authentication)
            try expectEqual(classify(429, #"{"error":{"message":"Rate limit reached"}}"#).kind, .rateLimit)
            try expectEqual(classify(429, #"{"error":{"message":"You exceeded your current quota"}}"#).kind, .quotaExhausted)
            try expectEqual(classify(503, #"{"error":{"message":"overloaded"}}"#).kind, .providerDown)
            try expectEqual(classify(500, #"{"error":{"message":"server error"}}"#).kind, .transient)
            try expectEqual(classify(404, #"{"error":{"message":"model not found"}}"#).kind, .modelUnavailable)
            try expectEqual(classify(400, #"{"error":{"message":"This model's maximum context length is 8192 tokens"}}"#).kind,
                            .contextOverflow)
            try expectEqual(classify(400, #"{"error":{"message":"Invalid value for temperature"}}"#).kind, .invalidRequest)
        }

        test("retry-after is captured for backoff") {
            let e = classify(429, #"{"error":{"message":"slow down"}}"#, headers: ["retry-after": "3"])
            try expectClose(try expectNotNil(e.retryAfter), 3, tolerance: 0.01)
        }

        test("credentials are redacted from provider error text") {
            let e = classify(401, #"{"error":{"message":"Incorrect API key provided: sk-abcdef1234567890abcdef"}}"#)
            try expect(!e.message.contains("sk-abcdef1234567890"), "keys must never reach a log or the UI")
            try expectContains(e.message, "REDACTED")
        }
    }

    suite("Providers / OpenAI over a stubbed endpoint") {
        test("a custom OpenAI-compatible endpoint completes a request") {
            let transport = MockTransport()
            transport.stub("/v1/chat/completions", json: """
            {"id":"1","model":"Qwen3-Coder-30B","choices":[{"message":{"role":"assistant","content":"pong"},
             "finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1}}
            """)
            var account = Fixture.account("Home Mac Studio", kind: .openAICompatible,
                                          models: [Fixture.model("Qwen3-Coder-30B")])
            account.baseURLOverride = "http://192.168.1.20:8000/v1"
            let response = try await OpenAIAdapter().execute(CanonicalRequest(requestedModel: "l"),
                                                             model: "Qwen3-Coder-30B",
                                                             ctx: ctx(account, transport: transport))
            try expectEqual(response.message.joinedText, "pong")
            let recorded = try expectNotNil(transport.requests.first)
            try expectEqual(recorded.url.absoluteString, "http://192.168.1.20:8000/v1/chat/completions")
        }

        test("model discovery reads /v1/models") {
            let transport = MockTransport()
            transport.stub("/v1/models", json: """
            {"object":"list","data":[{"id":"gpt-test-a"},{"id":"gpt-test-b"}]}
            """)
            let account = Fixture.account("Compatible", kind: .openAICompatible, models: [])
            let models = try await OpenAIAdapter().listModels(ctx(account, transport: transport))
            try expectEqual(models.count, 2)
            try expect(models.contains { $0.id == "gpt-test-a" })
        }

        test("Ollama discovery uses the native endpoint, which reports far more") {
            let transport = MockTransport()
            transport.stub("/api/tags", json: """
            {"models":[
              {"model":"qwen3.5:9b","size":6594474711,
               "details":{"family":"qwen35","parameter_size":"9.7B","quantization_level":"Q4_K_M",
                          "context_length":262144,"embedding_length":4096},
               "capabilities":["vision","completion","tools","thinking"]},
              {"model":"nomic-embed-text:latest","size":274302450,
               "details":{"family":"nomic-bert","context_length":8192,"embedding_length":768},
               "capabilities":["embedding"]}]}
            """)
            let account = Fixture.account("Ollama", kind: .ollama, models: [])
            let models = try await OpenAIAdapter().listModels(ctx(account, transport: transport))
            try expectEqual(models.count, 2)
            let chat = try expectNotNil(models.first { $0.id == "qwen3.5:9b" })
            try expectEqual(chat.capabilities?.contextWindow, 262_144,
                            "the compatible endpoint would have reported no window at all")
            try expect(chat.capabilities?.flags.contains(.vision) == true)
            try expectEqual(chat.profile?.parameterSize, "9.7B")
            let embedder = try expectNotNil(models.first { $0.id == "nomic-embed-text:latest" })
            try expect(embedder.capabilities?.flags.contains(.embeddings) == true)
            try expectEqual(embedder.capabilities?.embeddingDimensions, 768)
            // The native endpoint was used, not the compatible one.
            try expect(transport.requests.allSatisfy { !$0.url.path.hasSuffix("/v1/models") })
        }

        test("an API key is sent as a bearer token") {
            let transport = MockTransport()
            transport.stub("/v1/models", json: #"{"data":[]}"#)
            let ref = SecretRef(account: "test.key")
            let secrets = InMemorySecretStore(["test.key": "sk-secret-value"])
            var account = Fixture.account("OpenAI", kind: .openai, models: [])
            account.baseURLOverride = nil
            account.auth = .apiKey(ref)
            _ = try await OpenAIAdapter().listModels(ctx(account, transport: transport, secrets: secrets))
            let headers = try expectNotNil(transport.requests.first?.headers)
            try expectEqual(headers["authorization"], "Bearer sk-secret-value")
        }

        test("a missing API key produces a clear configuration error") {
            let transport = MockTransport()
            var account = Fixture.account("OpenAI", kind: .openai, models: [])
            account.auth = .apiKey(SecretRef(account: "absent"))
            let e = try await expectFailure(.authentication) {
                _ = try await OpenAIAdapter().listModels(ctx(account, transport: transport))
            }
            try expectContains(e.message, "No API key saved")
        }

        test("Azure uses the deployment path, api-key header and api-version") {
            let transport = MockTransport()
            transport.stub("/chat/completions", json: """
            {"id":"1","model":"dep","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
            """)
            let secrets = InMemorySecretStore(["azure": "azkey"])
            var account = Fixture.account("Azure", kind: .azureOpenAI, models: [Fixture.model("my-deployment")])
            account.baseURLOverride = "https://example.openai.azure.com"
            account.auth = .apiKey(SecretRef(account: "azure"))
            account.apiVersion = "2024-10-21"
            _ = try await OpenAIAdapter().execute(CanonicalRequest(requestedModel: "l"), model: "my-deployment",
                                                   ctx: ctx(account, transport: transport, secrets: secrets))
            let recorded = try expectNotNil(transport.requests.first)
            try expectContains(recorded.url.absoluteString, "/openai/deployments/my-deployment/chat/completions")
            try expectContains(recorded.url.absoluteString, "api-version=2024-10-21")
            try expectEqual(recorded.headers["api-key"], "azkey")
        }

        test("SSE deltas become canonical stream events") {
            let transport = MockTransport()
            transport.stubStream("/v1/chat/completions", events: [
                #"{"id":"1","model":"m","choices":[{"delta":{"role":"assistant"}}]}"#,
                #"{"id":"1","model":"m","choices":[{"delta":{"content":"Hel"}}]}"#,
                #"{"id":"1","model":"m","choices":[{"delta":{"content":"lo"}}]}"#,
                #"{"id":"1","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":""}}]}}]}"#,
                #"{"id":"1","model":"m","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":1}"}}]}}]}"#,
                #"{"id":"1","model":"m","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":9}}"#,
            ])
            let account = Fixture.account("Local", kind: .openAICompatible, models: [Fixture.model("m")])
            var request = CanonicalRequest(requestedModel: "l")
            request.stream = true
            var acc = StreamAccumulator()
            for try await e in try await OpenAIAdapter().stream(request, model: "m",
                                                                ctx: ctx(account, transport: transport)) {
                acc.ingest(e)
            }
            let response = acc.makeResponse(fallbackModel: "m")
            try expectEqual(response.message.joinedText, "Hello")
            try expectEqual(response.message.toolCalls.first?.name, "f")
            try expectEqual(response.message.toolCalls.first?.argumentsJSON, "{\"a\":1}")
            try expectEqual(response.usage.outputTokens, 9)
            try expectEqual(response.finishReason, .toolCalls)
        }

        test("an HTTP error while opening a stream is classified, not swallowed") {
            let transport = MockTransport()
            transport.stub("/v1/chat/completions", status: 429, json: #"{"error":{"message":"Rate limit"}}"#)
            let account = Fixture.account("Local", kind: .openAICompatible, models: [Fixture.model("m")])
            var request = CanonicalRequest(requestedModel: "l")
            request.stream = true
            _ = try await expectFailure(.rateLimit) {
                _ = try await OpenAIAdapter().stream(request, model: "m", ctx: ctx(account, transport: transport))
            }
        }

        test("embeddings are parsed") {
            let transport = MockTransport()
            transport.stub("/v1/embeddings", json: """
            {"object":"list","model":"e","data":[{"embedding":[0.1,0.2]},{"embedding":[0.3,0.4]}],
             "usage":{"prompt_tokens":6}}
            """)
            let account = Fixture.account("Local", kind: .openAICompatible, models: [Fixture.model("e")])
            let r = try await OpenAIAdapter().embed(CanonicalEmbeddingRequest(requestedModel: "l", inputs: ["a", "b"]),
                                                     model: "e", ctx: ctx(account, transport: transport))
            try expectEqual(r.vectors.count, 2)
            try expectEqual(r.vectors[0], [0.1, 0.2])
            try expectEqual(r.usage.inputTokens, 6)
        }
    }

    suite("Providers / Anthropic") {
        test("system messages are hoisted and tool results become user blocks") {
            let adapter = AnthropicAdapter(oauth: false)
            var r = CanonicalRequest(requestedModel: "l")
            r.messages = [
                .system("be terse"),
                .user("weather?"),
                CanonicalMessage(role: .assistant,
                                 toolCalls: [CanonicalToolCall(id: "t1", name: "w", argumentsJSON: "{}")]),
                CanonicalMessage(role: .tool, content: [.text("18C")], toolCallID: "t1"),
            ]
            r.maxOutputTokens = 256
            let account = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-x")])
            let body = try adapter.buildBody(r, model: "claude-x",
                                             ctx: ctx(account, transport: MockTransport()), stream: false)
            try expectEqual(body["system"]?[0]?["text"]?.stringValue, "be terse")
            try expectEqual(body["max_tokens"]?.intValue, 256)
            let msgs = try expectNotNil(body["messages"]?.arrayValue)
            try expectEqual(msgs.count, 3)
            try expectEqual(msgs[1]["content"]?[0]?["type"]?.stringValue, "tool_use")
            try expectEqual(msgs[2]["content"]?[0]?["type"]?.stringValue, "tool_result")
            try expectEqual(msgs[2]["role"]?.stringValue, "user")
        }

        test("max_tokens is always present, because the API requires it") {
            let adapter = AnthropicAdapter(oauth: false)
            let account = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-x")])
            let body = try adapter.buildBody(CanonicalRequest(requestedModel: "l"), model: "claude-sonnet-4-5",
                                             ctx: ctx(account, transport: MockTransport()), stream: false)
            try expect((body["max_tokens"]?.intValue ?? 0) > 0)
        }

        test("OAuth mode injects the Claude Code identity as the first system block") {
            let adapter = AnthropicAdapter(oauth: true)
            var r = CanonicalRequest(requestedModel: "l")
            r.messages = [.system("user system prompt"), .user("hi")]
            let account = Fixture.account("Claude sub", kind: .anthropicSubscription, models: [Fixture.model("claude-x")])
            let body = try adapter.buildBody(r, model: "claude-x",
                                             ctx: ctx(account, transport: MockTransport()), stream: false)
            let system = try expectNotNil(body["system"]?.arrayValue)
            try expectEqual(system[0]["text"]?.stringValue, AnthropicAdapter.claudeCodeIdentity)
            try expectEqual(system[1]["text"]?.stringValue, "user system prompt")
        }

        test("the OAuth identity is the CLI's, not a bare bearer token") {
            let h = ClaudeCodeIdentity.headers(version: "9.9.9")
            try expectEqual(h["user-agent"], "claude-code/9.9.9 (external, cli)")
            try expectEqual(h["x-app"], "cli")
            let betas = try expectNotNil(h["anthropic-beta"])
            // Both halves matter: one authorizes the bearer token, the other
            // names the caller. Sending only the first is what Derby used to do.
            for beta in ClaudeCodeIdentity.oauthBetas + ClaudeCodeIdentity.sessionBetas {
                try expectContains(betas, beta)
            }
        }

        test("the 1M-context beta is withheld, because it 400s accounts without it") {
            let betas = try expectNotNil(ClaudeCodeIdentity.headers(version: "1.0.0")["anthropic-beta"])
            for beta in ClaudeCodeIdentity.withheldBetas {
                try expect(!betas.contains(beta), "\(beta) breaks every request on an account that lacks it")
            }
        }

        test("an adapter's own user-agent survives the shared header helper") {
            let account = Fixture.account("Claude sub", kind: .anthropicSubscription,
                                          models: [Fixture.model("claude-x")])
            let context = ctx(account, transport: MockTransport())
            let adapter = AnthropicAdapter(oauth: true)

            let identity = ResolvedAuth(headers: ["user-agent": "claude-code/9.9.9 (external, cli)"])
            try expectEqual(adapter.headers(context, auth: identity)["user-agent"],
                            "claude-code/9.9.9 (external, cli)")
            // ...and the default still applies when an adapter states no identity.
            try expectEqual(adapter.headers(context, auth: ResolvedAuth())["user-agent"],
                            "Derby/1.0 (macOS)")
        }

        test("an OAuth account sends the identity on the wire, not just the token") {
            // A private credential home reads only its own file and never the
            // Keychain, so this runs offline and touches nothing the user owns.
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("derby-oauth-identity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let expiry = (Date().timeIntervalSince1970 + 3600) * 1000
            try #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(expiry)}}"#
                .write(to: home.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)

            var account = Fixture.account("Claude sub", kind: .anthropicSubscription,
                                          models: [Fixture.model("claude-x")])
            account.auth = .cli(source: .claudeCode, allowRefresh: false)
            account.credentialHomeOverride = home.path

            // Seeded so the suite never spawns `claude --version`.
            await ClaudeCodeVersion.shared.seed("9.9.9")
            let adapter = AnthropicAdapter(oauth: true)
            let auth = try await adapter.authenticate(ctx(account, transport: MockTransport()))
            let sent = adapter.headers(ctx(account, transport: MockTransport()), auth: auth)

            try expectEqual(sent["authorization"], "Bearer tok-abc")
            try expectEqual(sent["user-agent"], "claude-code/9.9.9 (external, cli)")
            try expectEqual(sent["x-app"], "cli")
            try expectContains(try expectNotNil(sent["anthropic-beta"]), "claude-code-20250219")
            try expectContains(try expectNotNil(sent["anthropic-beta"]), "oauth-2025-04-20")
        }

        test("the declared CLI version is the installed one, or nothing") {
            try expectEqual(ClaudeCodeVersion.parse("2.1.259 (Claude Code)"), "2.1.259")
            try expectEqual(ClaudeCodeVersion.parse("2.1.259"), "2.1.259")
            try expectNil(ClaudeCodeVersion.parse("Claude Code 2.1.259"),
                          "a non-numeric leading token is not a version")
            try expectNil(ClaudeCodeVersion.parse(""))
        }

        test("extended thinking sets a budget below max_tokens and drops temperature") {
            let adapter = AnthropicAdapter(oauth: false)
            var r = CanonicalRequest(requestedModel: "l")
            r.maxOutputTokens = 4096
            r.temperature = 0.7
            r.reasoning = ReasoningControls(effort: .high)
            let account = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-x")])
            let body = try adapter.buildBody(r, model: "claude-x",
                                             ctx: ctx(account, transport: MockTransport()), stream: false)
            let budget = try expectNotNil(body["thinking"]?["budget_tokens"]?.intValue)
            try expect(budget < 4096, "the thinking budget must stay under max_tokens")
            try expectNil(body["temperature"], "Anthropic rejects temperature while thinking is on")
        }

        test("parses a message response with thinking and tool use") {
            let adapter = AnthropicAdapter(oauth: false)
            let json = try expectNotNil(JSONValue.parse("""
            {"id":"msg_1","model":"claude-x","stop_reason":"tool_use",
             "content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Let me check"},
                        {"type":"tool_use","id":"tu1","name":"w","input":{"city":"Paris"}}],
             "usage":{"input_tokens":30,"output_tokens":12,"cache_read_input_tokens":20}}
            """))
            let r = try adapter.parseResponse(json, fallbackModel: "x")
            try expectEqual(r.message.reasoning, "hmm")
            try expectEqual(r.message.joinedText, "Let me check")
            try expectEqual(r.message.toolCalls.first?.name, "w")
            try expectEqual(r.finishReason, .toolCalls)
            try expectEqual(r.usage.cachedInputTokens, 20)
        }

        test("error classification, including overload and OAuth guidance") {
            let plain = AnthropicAdapter(oauth: false)
            try expectEqual(plain.classifyError(status: 529, headers: [:],
                                                body: Data(#"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8),
                                                model: "m").kind, .providerDown)
            try expectEqual(plain.classifyError(status: 400, headers: [:],
                                                body: Data(#"{"error":{"message":"prompt is too long: 250000 tokens"}}"#.utf8),
                                                model: "m").kind, .contextOverflow)
            let oauth = AnthropicAdapter(oauth: true)
            let authError = oauth.classifyError(status: 401, headers: [:],
                                                body: Data(#"{"error":{"message":"invalid token"}}"#.utf8), model: "m")
            try expectEqual(authError.kind, .authentication)
            try expectContains(authError.message, "sign in again")
        }

        test("a spent subscription allowance is quota, not a malformed request") {
            // Anthropic sends this as HTTP 400. Read literally that is
            // `invalidRequest`, whose disposition returns to the client — so a
            // healthy target that could have served the request never got tried.
            let body = Data(#"{"error":{"type":"invalid_request_error","message":"Third-party apps now draw from your extra usage, not your plan limits. Add more at claude.ai/settings/usage and keep going."}}"#.utf8)
            let oauth = AnthropicAdapter(oauth: true)
            let error = oauth.classifyError(status: 400, headers: [:], body: body, model: "claude-sonnet-4-5")
            try expectEqual(error.kind, .quotaExhausted)
            try expect(error.kind.defaultDisposition.allowsFailover,
                       "an exhausted allowance must fail over to a target that still has capacity")
            try expectContains(error.message, "Claude Code (plan limits)")

            // The metered 429 wording still classifies the same way.
            try expectEqual(AnthropicAdapter(oauth: false).classifyError(
                status: 429, headers: [:],
                body: Data(#"{"error":{"message":"Your credit balance is too low"}}"#.utf8),
                model: "m").kind, .quotaExhausted)
            // ...and an ordinary 400 is still an ordinary 400.
            try expectEqual(AnthropicAdapter(oauth: false).classifyError(
                status: 400, headers: [:],
                body: Data(#"{"error":{"message":"messages: at least one message is required"}}"#.utf8),
                model: "m").kind, .invalidRequest)
        }

        test("streaming events are translated") {
            let transport = MockTransport()
            transport.stubStream("/v1/messages", events: [
                #"{"type":"message_start","message":{"id":"msg_1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":0}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu1","name":"w"}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"c\":1}"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
                #"{"type":"message_stop"}"#,
            ])
            var account = Fixture.account("Anthropic", kind: .anthropic, models: [Fixture.model("claude-x")])
            account.baseURLOverride = "https://api.anthropic.com/v1"
            account.auth = .apiKey(SecretRef(account: "k"))
            let secrets = InMemorySecretStore(["k": "sk-ant-test"])
            var request = CanonicalRequest(requestedModel: "l")
            request.stream = true
            var acc = StreamAccumulator()
            for try await e in try await AnthropicAdapter(oauth: false)
                .stream(request, model: "claude-x", ctx: ctx(account, transport: transport, secrets: secrets)) {
                acc.ingest(e)
            }
            let r = acc.makeResponse(fallbackModel: "x")
            try expectEqual(r.message.joinedText, "Hi")
            try expectEqual(r.message.toolCalls.first?.argumentsJSON, "{\"c\":1}")
            try expectEqual(r.finishReason, .toolCalls)
            try expectEqual(r.usage.outputTokens, 7)
            try expectEqual(transport.requests.first?.headers["x-api-key"], "sk-ant-test")
        }
    }

    suite("Providers / Google") {
        test("builds contents, systemInstruction and tools") {
            let adapter = GoogleAdapter()
            var r = CanonicalRequest(requestedModel: "l")
            r.messages = [.system("be nice"), .user("hi"), .assistant("hello")]
            r.tools = [CanonicalTool(name: "f", description: "d",
                                     parameters: .object(["type": .string("object"),
                                                          "properties": .object(["a": .object(["type": .string("string")])]),
                                                          "additionalProperties": .bool(false)]))]
            r.maxOutputTokens = 64
            let body = adapter.buildBody(r, model: "gemini-x")
            try expectEqual(body["systemInstruction"]?["parts"]?[0]?["text"]?.stringValue, "be nice")
            try expectEqual(body["contents"]?[1]?["role"]?.stringValue, "model")
            try expectEqual(body["generationConfig"]?["maxOutputTokens"]?.intValue, 64)
            let params = try expectNotNil(body["tools"]?[0]?["functionDeclarations"]?[0]?["parameters"])
            try expectNil(params["additionalProperties"], "Gemini rejects this keyword; it must be stripped")
        }

        test("parses candidates, thoughts and usage") {
            let adapter = GoogleAdapter()
            let json = try expectNotNil(JSONValue.parse("""
            {"responseId":"r1","modelVersion":"gemini-x",
             "candidates":[{"finishReason":"STOP","content":{"parts":[
                {"text":"reasoning","thought":true},{"text":"answer"},
                {"functionCall":{"name":"f","args":{"a":"b"}}}]}}],
             "usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":4,"thoughtsTokenCount":2}}
            """))
            let r = try adapter.parseResponse(json, fallbackModel: "x")
            try expectEqual(r.message.reasoning, "reasoning")
            try expectEqual(r.message.joinedText, "answer")
            try expectEqual(r.message.toolCalls.first?.name, "f")
            try expectEqual(r.finishReason, .toolCalls)
            try expectEqual(r.usage.inputTokens, 9)
            try expectEqual(r.usage.reasoningTokens, 2)
        }

        test("a blocked prompt is a content-policy failure") {
            let adapter = GoogleAdapter()
            let json = try expectNotNil(JSONValue.parse(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#))
            _ = try await expectFailure(.contentPolicy) { _ = try adapter.parseResponse(json, fallbackModel: "x") }
        }
    }

    suite("Providers / adapter registry") {
        test("every provider kind maps to an adapter family") {
            let registry = AdapterRegistry.default
            for kind in ProviderKind.allCases {
                let adapter = registry.adapter(for: kind)
                try expectEqual(adapter.family, kind.adapterFamily, "wrong adapter for \(kind.rawValue)")
            }
        }

        test("subscription kinds are flat-rate and CLI-linked") {
            for kind in ProviderKind.allCases where kind.isSubscription {
                try expect(kind.cliCredentialSource != nil, "\(kind.rawValue) needs a credential source")
            }
            try expectEqual(ProviderKind.anthropicSubscription.cliCredentialSource, .claudeCode)
            try expectEqual(ProviderKind.chatgptSubscription.cliCredentialSource, .codexCLI)
        }

        test("local kinds default to loopback base URLs") {
            for kind in ProviderKind.allCases where kind.isLocal {
                let url = try expectNotNil(kind.defaultBaseURL, "\(kind.rawValue) should default to a local URL")
                try expectContains(url, "127.0.0.1")
            }
        }

        test("a registry override replaces one family only") {
            let mock = MockAdapter()
            let registry = AdapterRegistry.default.overriding(.openai, with: mock)
            try expect(registry.adapter(for: AdapterFamily.openai) is MockAdapter)
            try expect(registry.adapter(for: AdapterFamily.anthropic) is AnthropicAdapter)
        }
    }

    suite("Providers / SigV4") {
        test("produces a well-formed authorization header") {
            let url = try expectNotNil(URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/model/x/converse"))
            let headers = AWSSigV4.sign(method: "POST", url: url,
                                        headers: ["content-type": "application/json"],
                                        body: Data("{}".utf8), region: "us-east-1", service: "bedrock",
                                        credentials: .init(accessKeyID: "AKID", secretAccessKey: "SECRET"))
            let auth = try expectNotNil(headers["authorization"])
            try expectContains(auth, "AWS4-HMAC-SHA256")
            try expectContains(auth, "Credential=AKID/")
            try expectContains(auth, "/us-east-1/bedrock/aws4_request")
            try expectContains(auth, "SignedHeaders=")
            try expect(headers["x-amz-date"] != nil)
            try expect(headers["x-amz-content-sha256"] != nil)
        }

        test("event-stream frames are decoded") {
            // One frame: headers {":event-type": "contentBlockDelta"}, JSON payload.
            let payload = Data(#"{"delta":{"text":"hi"}}"#.utf8)
            let name = ":event-type"
            let value = "contentBlockDelta"
            var headers = Data()
            headers.append(UInt8(name.utf8.count))
            headers.append(contentsOf: Array(name.utf8))
            headers.append(7)
            headers.append(UInt8(value.utf8.count >> 8))
            headers.append(UInt8(value.utf8.count & 0xFF))
            headers.append(contentsOf: Array(value.utf8))

            let total = 12 + headers.count + payload.count + 4
            var frame = Data()
            for shift in [24, 16, 8, 0] { frame.append(UInt8((total >> shift) & 0xFF)) }
            for shift in [24, 16, 8, 0] { frame.append(UInt8((headers.count >> shift) & 0xFF)) }
            frame.append(contentsOf: [0, 0, 0, 0])   // prelude CRC (not validated)
            frame.append(headers)
            frame.append(payload)
            frame.append(contentsOf: [0, 0, 0, 0])   // message CRC

            var parser = AWSEventStreamParser()
            let frames = parser.consume(frame)
            try expectEqual(frames.count, 1)
            try expectEqual(frames[0].eventType, "contentBlockDelta")
            let json = try expectNotNil(JSONValue.parse(String(decoding: frames[0].payload, as: UTF8.self)))
            try expectEqual(json["delta"]?["text"]?.stringValue, "hi")
        }
    }
}

func registerAPIKeyTests() {
    func ctx(_ account: ProviderAccount, transport: MockTransport,
             secrets: InMemorySecretStore = InMemorySecretStore()) -> ProviderContext {
        ProviderContext(account: account, transport: transport, secrets: secrets,
                        credentials: CredentialCache(), attemptTimeout: 5)
    }

    suite("Providers / API key requirement") {
        test("each kind declares exactly one requirement") {
            // The Add Provider form renders one field from this, rather than
            // overlapping conditions — which is what produced two key boxes.
            for kind in ProviderKind.allCases {
                let requirement = kind.apiKeyRequirement
                if kind.cliCredentialSource != nil || kind == .bedrock {
                    try expectEqual(requirement, .notApplicable,
                                    "\(kind.rawValue) gets credentials elsewhere")
                } else if kind.isLocal || kind == .openAICompatible {
                    try expectEqual(requirement, .optional, "\(kind.rawValue) may be unauthenticated")
                } else {
                    try expectEqual(requirement, .required, "\(kind.rawValue) is a metered API")
                }
            }
        }

        test("a custom endpoint works with no key at all") {
            // No Authorization header should be sent, and nothing should fail for
            // want of a credential that was never needed.
            let transport = MockTransport()
            transport.stub("/v1/chat/completions", json: """
            {"id":"1","model":"m","choices":[{"message":{"role":"assistant","content":"ok"},
             "finish_reason":"stop"}]}
            """)
            var account = Fixture.account("Private server", kind: .openAICompatible,
                                          models: [Fixture.model("m")])
            account.auth = .none
            let response = try await OpenAIAdapter().execute(CanonicalRequest(requestedModel: "l"),
                                                             model: "m",
                                                             ctx: ctx(account, transport: transport))
            try expectEqual(response.message.joinedText, "ok")
            let headers = try expectNotNil(transport.requests.first?.headers)
            try expectNil(headers["authorization"], "no key means no Authorization header")
        }

        test("the same endpoint sends a bearer token once a key is added") {
            let transport = MockTransport()
            transport.stub("/v1/chat/completions", json: """
            {"id":"1","model":"m","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
            """)
            let ref = SecretRef(account: "custom.key")
            var account = Fixture.account("Private server", kind: .openAICompatible,
                                          models: [Fixture.model("m")])
            account.auth = .apiKey(ref)
            let secrets = InMemorySecretStore(["custom.key": "sk-private"])
            _ = try await OpenAIAdapter().execute(CanonicalRequest(requestedModel: "l"), model: "m",
                                                   ctx: ctx(account, transport: transport, secrets: secrets))
            try expectEqual(transport.requests.first?.headers["authorization"], "Bearer sk-private")
        }

        test("a metered provider missing its key fails with an actionable error") {
            var account = Fixture.account("OpenAI", kind: .openai, models: [Fixture.model("m")])
            account.auth = .apiKey(SecretRef(account: "absent"))
            let error = try await expectFailure(.authentication) {
                _ = try await OpenAIAdapter().execute(CanonicalRequest(requestedModel: "l"), model: "m",
                                                       ctx: ctx(account, transport: MockTransport()))
            }
            try expectContains(error.message, "No API key saved")
        }
    }
}
