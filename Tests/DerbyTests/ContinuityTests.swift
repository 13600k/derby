import Foundation
@testable import DerbyCore

/// A conversation staying one conversation on the provider's side: on the
/// account that holds its reasoning and cached prompt, under the same session
/// id after its client rewrites how the history begins, and with its reasoning
/// intact across a Derby restart.
func registerContinuityTests() {

    func origin(_ model: String, account: UUID) -> MessageOrigin {
        MessageOrigin(modelID: model, providerKind: ProviderKind.chatgptSubscription.rawValue, accountID: account)
    }
    func sealed(_ payload: String, account: UUID) -> ReasoningArtifact {
        ReasoningArtifact(format: .openAIEncryptedReasoning, payload: payload, itemID: "rs_\(payload)",
                          originModel: "gpt-5.6-sol", originAccount: account)
    }

    suite("Continuity / account") {
        func accounts() -> (ProviderAccount, ProviderAccount) {
            (Fixture.account("ChatGPT alt1", kind: .chatgptSubscription, models: [Fixture.model("gpt-5.6-sol")]),
             Fixture.account("ChatGPT main", kind: .chatgptSubscription, models: [Fixture.model("gpt-5.6-sol")]))
        }
        func decide(_ config: DerbyConfig, conversationAccount: UUID?,
                    health: [TargetKey: TargetHealth] = [:]) throws -> RoutingDecision {
            try Router().route(RoutingRequest(logicalModelName: "smart",
                                              requirements: CapabilityRequirements(required: [.text]),
                                              promptTokens: 100, conversationAccount: conversationAccount),
                               snapshot: Fixture.snapshot(config, health: health))
        }
        func order(_ decision: RoutingDecision) -> [String] { decision.plan.attempts.map(\.target.providerName) }

        test("a conversation stays on the account that holds its reasoning, even against a failover order") {
            let (alt1, main) = accounts()
            let config = Fixture.config(accounts: [alt1, main], logicalModels: [
                Fixture.logical("smart", accounts: [alt1, main], strategy: .failoverChain),
            ])
            try expectEqual(order(try decide(config, conversationAccount: nil)), ["ChatGPT alt1", "ChatGPT main"],
                            "a new conversation follows the configured order")
            let continuing = try decide(config, conversationAccount: main.id)
            try expectEqual(order(continuing), ["ChatGPT main", "ChatGPT alt1"],
                            "moving back to alt1 would reprocess the history and lose main's reasoning")
            try expectContains(continuing.explanation, "reasoning")
        }

        test("only copies of one model are reordered, and an account that cannot answer is not kept") {
            let (alt1, main) = accounts()
            let claude = Fixture.account("Claude", kind: .anthropicSubscription, models: [Fixture.model("claude-opus-5")])
            let config = Fixture.config(accounts: [alt1, main, claude], logicalModels: [
                Fixture.logical("smart", accounts: [alt1, main, claude], strategy: .failoverChain),
            ])
            try expectEqual(order(try decide(config, conversationAccount: claude.id)),
                            ["ChatGPT alt1", "ChatGPT main", "Claude"], "which model answers stays the strategy's decision")
            var open = TargetHealth(key: TargetKey(providerID: main.id, modelID: "gpt-5.6-sol"))
            open.circuit = .open
            try expectEqual(order(try decide(config, conversationAccount: main.id, health: [open.key: open])),
                            ["ChatGPT alt1", "Claude"], "an account that cannot answer hands the conversation over")
        }

        test("the latest answer's account is the one that counts, and the preference can be turned off") {
            let (alt1, main) = accounts()
            let request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("q1"), CanonicalMessage(role: .assistant, content: [.text("a1")], origin: origin("gpt-5.6-sol", account: alt1.id)),
                .user("q2"), CanonicalMessage(role: .assistant, content: [.text("a2")], origin: origin("gpt-5.6-sol", account: main.id)),
                .user("q3"),
            ])
            try expectEqual(RoutingRequest(request).conversationAccount, main.id)

            var lm = Fixture.logical("smart", accounts: [alt1, main], strategy: .failoverChain)
            lm.policy.keepConversationsOnAccount = false
            let config = Fixture.config(accounts: [alt1, main], logicalModels: [lm])
            try expectEqual(order(try decide(config, conversationAccount: main.id)), ["ChatGPT alt1", "ChatGPT main"])

            let saved = try JSONEncoder().encode(RoutingPolicy())
            try expect(try JSONDecoder().decode(RoutingPolicy.self, from: saved).effectiveKeepConversationsOnAccount,
                       "a policy saved before the setting existed keeps conversations on their account")
        }
    }

    suite("Continuity / session id") {
        test("a conversation keeps its session id after its client rewrites how the history begins") {
            let ledger = HandoffLedger()
            let account = UUID()
            let opening = CanonicalRequest(requestedModel: "smart", messages: [
                .system("You are Hermes. Today is Friday."), .user("Refactor the parser."),
            ])
            let session = opening.conversationID(scope: account.uuidString)
            let answer = CanonicalMessage(role: .assistant,
                                          toolCalls: [CanonicalToolCall(id: "call_A1b2C3", name: "read", argumentsJSON: "{}")])
            await ledger.record(request: opening, response: answer, origin: origin("gpt-5.6-sol", account: account))

            // Compression: a rebuilt system prompt, the first turns replaced by a
            // summary, the recent turns kept.
            let compressed = CanonicalRequest(requestedModel: "smart", messages: [
                .system("You are Hermes. Today is Saturday."),
                .user("[CONTEXT SUMMARY] The user asked for a parser refactor; it is under way."),
                answer,
                CanonicalMessage(role: .tool, content: [.text("file contents")], toolCallID: "call_A1b2C3"),
            ])
            try expect(compressed.conversationID(scope: account.uuidString) != session,
                       "by its opening alone it would look like a new conversation")
            try expectEqual(await ledger.annotate(compressed).conversationID(scope: account.uuidString), session)

            let unrelated = await ledger.annotate(CanonicalRequest(requestedModel: "smart", messages: [
                .system("You are Hermes. Today is Saturday."), .user("Something else entirely."),
            ]))
            try expect(unrelated.conversationID(scope: account.uuidString) != session)
        }

        test("a client's own key still names the conversation") {
            var recorded = CanonicalRequest(requestedModel: "smart", messages: [.user("hi")])
            recorded.continuesConversation = "a-conversation-derby-recorded"
            recorded.promptCacheKey = "session-42"
            var other = CanonicalRequest(requestedModel: "smart", messages: [.user("something different")])
            other.promptCacheKey = "session-42"
            try expectEqual(recorded.conversationID(scope: "account"), other.conversationID(scope: "account"))
        }
    }

    suite("Continuity / rewritten history") {
        /// Compaction does not only drop turns: it rewrites them. A summary
        /// replaces the opening, a long tool result is trimmed to a line. The
        /// answers themselves come back untouched, so they are what Derby
        /// recognizes the conversation by.
        let answer = String(repeating: "The migration runs in three phases, each reversible. ", count: 5)

        test("an answer whose question was rewritten still names its conversation") {
            let ledger = HandoffLedger()
            let account = UUID()
            let first = CanonicalRequest(requestedModel: "smart", messages: [
                .user("Here is the full 40-page migration plan: …(the whole document)…"),
                .user("What does it say?"),
            ])
            await ledger.record(request: first, response: .assistant(answer),
                                origin: origin("gpt-5.6-sol", account: account))

            // What the client sends next: the document replaced by a summary,
            // the question it asked rewritten, the answer kept verbatim.
            let compressed = CanonicalRequest(requestedModel: "smart", messages: [
                .user("[earlier turns compressed] A migration plan was reviewed."),
                .assistant(answer),
                .user("Which phase is reversible?"),
            ])
            let annotated = await ledger.annotate(compressed)
            try expectEqual(annotated.conversationKey, first.conversationKey,
                            "the session survives the client rewriting everything around the answer")
            try expectEqual(annotated.messages[1].origin?.accountID, account,
                            "and the answer is still attributed to the account that wrote it")
        }

        test("a short answer is only recognized with the turn it answered") {
            let ledger = HandoffLedger()
            let request = CanonicalRequest(requestedModel: "smart", messages: [.user("ready?")])
            await ledger.record(request: request, response: .assistant("Done."),
                                origin: origin("gpt-5.6-sol", account: UUID()))
            let rewritten = CanonicalRequest(requestedModel: "smart", messages: [
                .user("something else entirely"), .assistant("Done."), .user("and now?"),
            ])
            try expectNil(await ledger.annotate(rewritten).messages[1].origin,
                          "'Done.' is not evidence of which conversation this is")
        }
    }

    suite("Continuity / restarts") {
        func temporaryDatabase() -> String {
            NSTemporaryDirectory() + "derby-ledger-\(UUID().uuidString).sqlite3"
        }

        test("a restart keeps what replaying an answer's reasoning needs, but not its plain text") {
            let account = UUID()
            let path = temporaryDatabase()
            let disk = SQLiteHandoffLedgerStore(path: path)
            let before = HandoffLedger()
            await before.attach(store: disk)
            let question = CanonicalRequest(requestedModel: "smart", messages: [.system("rules"), .user("Fix the parser.")])
            await before.record(request: question,
                                response: CanonicalMessage(role: .assistant, content: [.text("Fixed it.")],
                                                           reasoning: "plain thinking",
                                                           reasoningArtifacts: [sealed("sealed-1", account: account)]),
                                origin: origin("gpt-5.6-sol", account: account))
            disk.flush()

            let after = HandoffLedger()
            await after.attach(store: SQLiteHandoffLedgerStore(path: path))
            let restored = await after.annotate(CanonicalRequest(requestedModel: "smart", messages: [
                .system("rules"), .user("Fix the parser."), .assistant("Fixed it."), .user("Now the tests."),
            ]))
            try expectEqual(restored.messages[2].reasoningArtifacts.map(\.payload), ["sealed-1"])
            try expectEqual(restored.messages[2].origin?.accountID, account)
            try expectNil(restored.messages[2].reasoning, "plain-text reasoning is never written to disk")
            try expectEqual(restored.conversationID(scope: account.uuidString), question.conversationID(scope: account.uuidString))
        }

        test("what the ledger forgets is forgotten on disk too, and stale entries do not come back") {
            let path = temporaryDatabase()
            let disk = SQLiteHandoffLedgerStore(path: path)
            let ledger = HandoffLedger(limits: .init(maxEntries: 2, maxAge: 100))
            let start = Date(timeIntervalSince1970: 1_000_000)
            await ledger.attach(store: disk, now: start)
            for i in 0..<3 {
                await ledger.record(request: CanonicalRequest(requestedModel: "m", messages: [.user("q\(i)")]),
                                    response: .assistant("a\(i)"), origin: origin("gpt-5.6-sol", account: UUID()), at: start)
            }
            disk.flush()
            try expectEqual(SQLiteHandoffLedgerStore(path: path).load().count, 2, "the evicted entry was deleted")

            let later = HandoffLedger(limits: .init(maxEntries: 2, maxAge: 100))
            await later.attach(store: SQLiteHandoffLedgerStore(path: path), now: start.addingTimeInterval(500))
            try expectEqual(await later.count, 0, "nothing past the age limit is reloaded")
        }
    }

    // MARK: - Handing a tool loop to the second subscription

    suite("Continuity / another account") {
        /// A conversation cut off exactly where it hurts: the model has thought,
        /// called a tool and the result is back, and only then does its account
        /// run out. What the second account receives has to be the same
        /// conversation, thinking included.
        func interruptedToolLoop(account: UUID) -> CanonicalRequest {
            CanonicalRequest(requestedModel: "smart", messages: [
                .user("check order 4471"),
                CanonicalMessage(role: .assistant,
                                 toolCalls: [CanonicalToolCall(id: "call_1", name: "orders", argumentsJSON: "{}")],
                                 reasoningArtifacts: [sealed("mid-loop", account: account)],
                                 origin: origin("gpt-5.6-sol", account: account)),
                CanonicalMessage(role: .tool, content: [.text("shipped")], toolCallID: "call_1"),
            ])
        }

        test("a tool loop interrupted mid-thought reaches the second subscription with its thinking") {
            let first = UUID(), second = UUID()
            let plan = HandoffPlanner.plan(interruptedToolLoop(account: first),
                                           for: HandoffTarget(modelID: "gpt-5.6-sol",
                                                              providerKind: .chatgptSubscription,
                                                              accountID: second))
            try expectEqual(plan.record.signedReasoningCarried, 1)
            try expectEqual(plan.record.signedReasoningWithheld, 0)
            let input = try expectNotNil(ChatGPTCodexAdapter()
                .buildBody(plan.request, model: "gpt-5.6-sol")["input"]?.arrayValue)
            try expectEqual(input.compactMap { $0["type"]?.stringValue },
                            ["message", "reasoning", "function_call", "function_call_output"],
                            "the second account sees the thinking, the call and its result, in that order")
            try expectEqual(input[1]["encrypted_content"]?.stringValue, "mid-loop")
        }

        test("the second account names the conversation its own way, so its own prompt cache keeps working") {
            let request = interruptedToolLoop(account: UUID())
            let first = request.conversationID(scope: "account-one")
            let second = request.conversationID(scope: "account-two")
            try expect(first != second, "a cache key is only meaningful inside one account")
            try expectEqual(request.conversationID(scope: "account-two"), second,
                            "but it is the same on every turn that account serves")
        }
    }

    // MARK: - When a backend refuses what was replayed

    suite("Continuity / refused reasoning") {
        /// The backend verifies encrypted reasoning, so a payload it will not
        /// read is a 400 on the whole request. That must cost the thinking, not
        /// the turn.
        func setup() -> (MockAdapter, Executor, RecordingSink, RoutingDecision, CanonicalRequest) {
            let adapter = MockAdapter()
            let sink = RecordingSink()
            let account = Fixture.account("ChatGPT main", kind: .chatgptSubscription,
                                          models: [Fixture.model("gpt-5.6-sol")])
            let executor = Executor(registry: AdapterRegistry(adapters: [.chatgptCodex: adapter]),
                                    transport: MockTransport(), secrets: InMemorySecretStore(),
                                    credentials: CredentialCache(),
                                    health: HealthRegistry(settings: HealthSettings()), telemetry: sink)
            let config = Fixture.config(accounts: [account],
                                        logicalModels: [Fixture.logical("smart", accounts: [account])])
            let decision = try! Fixture.decision(config, model: "smart")
            var request = CanonicalRequest(requestedModel: "smart", messages: [
                .user("q"),
                CanonicalMessage(role: .assistant, content: [.text("a")],
                                 reasoningArtifacts: [sealed("stale", account: UUID())],
                                 origin: origin("gpt-5.6-sol", account: UUID())),
                .user("q2"),
            ])
            request.tools = [CanonicalTool(name: "orders", parameters: .object([:]))]
            return (adapter, executor, sink, decision, request)
        }

        let refusal = DerbyError(kind: .reasoningRejected,
                                 message: "The encrypted content for item rs_1 could not be verified.")

        test("reasoning the backend will not verify is re-sent without it, not failed") {
            let (adapter, executor, _, decision, request) = setup()
            adapter.set("gpt-5.6-sol", .failThenSucceed(count: 1, error: refusal, text: "answered"))
            let outcome = try await executor.execute(request, decision: decision, meta: RequestMeta())
            try expectEqual(outcome.response.message.joinedText, "answered")
            try expectEqual(adapter.calls("gpt-5.6-sol"), 2, "the same target was asked again")
            let sent = adapter.seen.map { $0.request.messages[1].reasoningArtifacts.count }
            try expectEqual(sent, [1, 0], "the retry withheld exactly what was refused")
            let record = try expectNotNil(outcome.record.attempts.last?.handoff)
            try expect(record.adjustments.contains { $0.contains("without the replayed reasoning") },
                       "a repair is never silent: \(record.adjustments)")
        }

        test("a stream refused before its first byte is repaired on the same target") {
            let (adapter, executor, _, decision, request) = setup()
            adapter.set("gpt-5.6-sol", .failThenSucceed(count: 1, error: refusal, text: "streamed"))
            var streamed = CanonicalRequest(requestedModel: "smart", messages: request.messages)
            streamed.tools = request.tools
            streamed.stream = true

            var text = ""
            var record: RequestRecord?
            for try await event in executor.stream(streamed, decision: decision, meta: RequestMeta()) {
                switch event {
                case .canonical(.textDelta(let t)): text += t
                case .finished(let r): record = r
                default: break
                }
            }
            try expectEqual(text.trimmingCharacters(in: .whitespaces), "streamed")
            let r = try expectNotNil(record)
            try expect(r.succeeded, "the client never sees the refusal")
            try expectEqual(r.finalProviderName, "ChatGPT main", "and never leaves the account it was on")
            try expectEqual(adapter.seen.map { $0.request.messages[1].reasoningArtifacts.count }, [1, 0])
        }

        test("a target that refuses twice is not asked a third time") {
            let (adapter, executor, _, decision, request) = setup()
            adapter.set("gpt-5.6-sol", .fail(refusal))
            do {
                _ = try await executor.execute(request, decision: decision, meta: RequestMeta())
                throw TestFailure(message: "the request should have failed", file: #fileID, line: #line)
            } catch let error as DerbyError {
                try expectEqual(error.kind, .reasoningRejected)
            }
            try expectEqual(adapter.calls("gpt-5.6-sol"), 2, "one repair, then the error is the client's")
        }
    }
}
