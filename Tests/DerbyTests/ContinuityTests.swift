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
}
