import Foundation
@testable import DerbyCore

func registerClaudeCLITests() {

    func context(_ configure: (inout ProviderAccount) -> Void = { _ in }) -> ProviderContext {
        var account = ProviderAccount(name: "Claude Code", kind: .claudeCodeCLI,
                                      auth: .cli(source: .claudeCode, allowRefresh: false))
        account.models = [PhysicalModel(modelID: "sonnet")]
        configure(&account)
        return ProviderContext(account: account, transport: MockTransport(),
                               secrets: InMemorySecretStore(), credentials: CredentialCache(),
                               attemptTimeout: 60)
    }

    suite("Claude CLI / routing identity") {
        test("the CLI kind is a subscription that maps to its own adapter") {
            try expect(ProviderKind.claudeCodeCLI.isSubscription)
            try expectEqual(ProviderKind.claudeCodeCLI.adapterFamily, .claudeCLI)
            try expectEqual(ProviderKind.claudeCodeCLI.cliCredentialSource, .claudeCode)
            try expect(AdapterRegistry.default.adapter(for: ProviderKind.claudeCodeCLI) is ClaudeCLIAdapter)
            // It runs a program; there is no endpoint to call.
            try expectNil(ProviderKind.claudeCodeCLI.defaultBaseURL)
            try expectEqual(ProviderKind.claudeCodeCLI.apiKeyRequirement, .notApplicable)
        }

        test("the two Claude subscription paths are distinguishable in the UI") {
            // One draws on plan limits, the other on extra usage; the names have
            // to say so, because picking the wrong one is the whole problem.
            try expectContains(ProviderKind.claudeCodeCLI.displayName, "plan limits")
            try expectContains(ProviderKind.anthropicSubscription.displayName, "extra usage")
        }
    }

    suite("Claude CLI / request shaping") {
        test("a single-turn request is passed through untouched") {
            let prompt = ClaudeCLIAdapter.renderPrompt([.user("Explain the CAP theorem.")])
            try expectEqual(prompt, "Explain the CAP theorem.")
        }

        test("a conversation is rendered as one turn") {
            // The CLI answers every input message in sequence, so history cannot
            // be replayed as separate messages without it replying to each.
            let prompt = ClaudeCLIAdapter.renderPrompt([
                .user("My favourite colour is teal."),
                .assistant("Noted."),
                .user("What is it?"),
            ])
            try expectContains(prompt, "teal")
            try expectContains(prompt, "Assistant: Noted.")
            try expectContains(prompt, "What is it?")
            try expect(prompt.hasSuffix("What is it?"), "the latest message must come last")
        }

        test("system messages become the system prompt, not part of the turn") {
            let messages: [CanonicalMessage] = [.system("Be terse."), .user("Hello")]
            try expectEqual(ClaudeCLIAdapter.systemPrompt(messages), "Be terse.")
            try expectEqual(ClaudeCLIAdapter.renderPrompt(messages), "Hello")
        }

        test("with no system message a neutral default is used") {
            try expectEqual(ClaudeCLIAdapter.systemPrompt([.user("Hi")]),
                            ClaudeCLIAdapter.defaultSystemPrompt)
        }

        test("the invocation strips Claude Code's own context") {
            // Without these the CLI carries its agent system prompt, tool schemas
            // and project files: ~27k tokens of overhead per request versus ~300.
            let args = ClaudeCLIAdapter.baseArguments(systemPrompt: "S")
            for expected in ["--print", "--tools", "--strict-mcp-config", "--setting-sources",
                             "--no-session-persistence", "--system-prompt"] {
                try expect(args.contains(expected), "missing \(expected)")
            }
            try expectEqual(args[args.firstIndex(of: "--tools")! + 1], "", "no built-in tools")
            try expectEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "", "no CLAUDE.md or settings")
        }

        test("an API key in the environment is removed") {
            // Otherwise the CLI would bill the request to that key instead of the
            // subscription, defeating the point of this provider.
            let env = ClaudeCLIAdapter().environment(context())
            try expectNil(env["ANTHROPIC_API_KEY"])
            try expectNil(env["ANTHROPIC_AUTH_TOKEN"])
        }

        test("PATH is repaired for an app launched from Finder") {
            // A GUI app inherits /usr/bin:/bin:/usr/sbin:/sbin, which is why this
            // worked from a terminal and not from the app.
            let env = ClaudeCLIAdapter().environment(context())
            let path = try expectNotNil(env["PATH"])
            try expectContains(path, ".local/bin")
            try expectContains(path, "/opt/homebrew/bin")
        }

        test("an account directory selects which Claude login is used") {
            let env = ClaudeCLIAdapter().environment(context { $0.credentialHomeOverride = "~/.claude-work" })
            try expectContains(try expectNotNil(env["CLAUDE_CONFIG_DIR"]), ".claude-work")
        }
    }

    suite("Claude CLI / capabilities") {
        test("tools and images are not claimed on this path") {
            // The CLI runs its own agent loop and takes no caller-supplied tool
            // schemas, so such requests must route to a different target.
            let base = ModelCapabilities(flags: [.text, .streaming, .tools, .vision, .reasoning],
                                         contextWindow: 1_000_000)
            let caps = ClaudeCLIAdapter.capabilities(base)
            try expect(caps.flags.contains(.text))
            try expect(caps.flags.contains(.streaming))
            try expect(caps.flags.contains(.reasoning))
            try expect(!caps.flags.contains(.tools))
            try expect(!caps.flags.contains(.vision))
            try expectEqual(caps.contextWindow, 1_000_000, "the window still applies")
        }

        test("sampling parameters are declared unsupported") {
            let caps = ClaudeCLIAdapter.capabilities(ModelCapabilities(flags: [.text]))
            try expect(!caps.allows(.temperature))
            try expect(!caps.allows(.topP))
            try expect(!caps.allows(.stop))
        }

        test("a tool request routes away from a CLI target") {
            var cliModel = Fixture.model("sonnet", caps: [.text, .streaming])
            cliModel.capabilities.source = .discovered
            let cli = Fixture.account("Claude Code", kind: .claudeCodeCLI, models: [cliModel])
            let api = Fixture.account("Other", models: [Fixture.model("m", caps: [.text, .streaming, .tools])])
            let config = Fixture.config(accounts: [cli, api],
                                        logicalModels: [Fixture.logical("coding", accounts: [cli, api])])
            var request = CanonicalRequest(requestedModel: "coding")
            request.tools = [CanonicalTool(name: "f")]
            let decision = try Router().route(RoutingRequest(request), snapshot: Fixture.snapshot(config))
            try expectEqual(decision.plan.attempts.count, 1)
            try expectEqual(decision.plan.attempts[0].target.providerName, "Other")
        }
    }

    suite("Claude CLI / failure handling") {
        test("a silent process is reported as a Keychain prompt, not a timeout") {
            // The first launch from Derby raises a macOS authorization dialog for
            // the CLI, and until it is answered the process simply sits there.
            let error = ClaudeCLIAdapter.keychainPromptError
            try expectEqual(error.kind, .authentication)
            try expectContains(error.message, "Keychain")
            try expectContains(error.message, "Always Allow")
        }

        test("CLI failure text maps onto the taxonomy") {
            try expectEqual(ClaudeCLIAdapter.classify(stderr: "Not logged in. Please run claude login").kind,
                            .authentication)
            try expectEqual(ClaudeCLIAdapter.classify(stderr: "You have reached your usage limit").kind,
                            .quotaExhausted)
            try expectEqual(ClaudeCLIAdapter.classify(stderr: "Overloaded, try again").kind, .providerDown)
            try expectEqual(ClaudeCLIAdapter.classify(stderr: "command not found: claude").kind, .authentication)
            try expectEqual(ClaudeCLIAdapter.classify(stderr: "something odd").kind, .transient)
        }

        test("credentials never leak into an error message") {
            let error = ClaudeCLIAdapter.classify(stderr: "failed with token sk-ant-oat01-abcdefghijklmnop")
            try expect(!error.message.contains("sk-ant-oat01-abcdefghijklmnop"))
        }
    }

    suite("Claude CLI / plan usage") {
        test("plan utilization becomes routable quota pressure") {
            // The CLI reports how much of the rolling windows is spent, which is
            // exactly what is needed to route away from a nearly-exhausted plan.
            let event = try expectNotNil(JSONValue.parse("""
            {"type":"rate_limit_event","rate_limit_info":{"status":"allowed",
              "unifiedWindows":{"five_hour":{"utilization":0.9,"resetsAt":9999999999},
                                "seven_day":{"utilization":0.4,"resetsAt":9999999999}}}}
            """))
            let snapshot = try expectNotNil(ClaudeCLIAdapter.rateLimit(from: event))
            try expectClose(snapshot.pressure, 0.9, tolerance: 0.02, "the worst window wins")
            try expect(!snapshot.isExhausted)
        }

        test("a rejected request is treated as exhausted") {
            let event = try expectNotNil(JSONValue.parse("""
            {"type":"rate_limit_event","rate_limit_info":{"status":"rejected",
              "unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":9999999999}}}}
            """))
            let snapshot = try expectNotNil(ClaudeCLIAdapter.rateLimit(from: event))
            try expect(snapshot.isExhausted)
            try expectEqual(snapshot.pressure, 1)
        }

        test("usage is read from the CLI's own accounting") {
            let usage = ClaudeCLIAdapter.parseUsage(try expectNotNil(JSONValue.parse("""
            {"input_tokens":292,"output_tokens":5,"cache_read_input_tokens":10,
             "cache_creation_input_tokens":27237,"output_tokens_details":{"thinking_tokens":3}}
            """)))
            try expectEqual(usage.inputTokens, 292)
            try expectEqual(usage.outputTokens, 5)
            try expectEqual(usage.cachedInputTokens, 10)
            try expectEqual(usage.cacheWriteTokens, 27237)
            try expectEqual(usage.reasoningTokens, 3)
        }
    }

    suite("Claude CLI / process runner") {
        test("a local command streams its output") {
            var lines: [String] = []
            for try await line in ProcessRunner.streamLines(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["one two", "three"],
                environment: ProcessInfo.processInfo.environment) {
                lines.append(line)
            }
            try expectEqual(lines, ["one two three"])
        }

        test("a failing command surfaces its stderr") {
            let error = try await expectThrows {
                for try await _ in ProcessRunner.streamLines(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo bad things >&2; exit 3"],
                    environment: [:]) {}
            }
            let failure = try expectNotNil(error as? ProcessRunner.Failure)
            try expectEqual(failure.status, 3)
            try expectContains(failure.stderr, "bad things")
        }

        test("an executable is found even when PATH is unhelpful") {
            try expect(ProcessRunner.locate("sh") != nil)
            try expectNil(ProcessRunner.locate("definitely-not-a-real-binary-xyz"))
        }
    }
}
