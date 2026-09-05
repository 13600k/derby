import Foundation

/// Uses a Claude subscription by running the `claude` CLI.
///
/// Anthropic distinguishes first-party clients from third-party ones — the
/// source of "Third-party apps now draw from your extra usage, not your plan
/// limits." Running the CLI is unambiguously first-party, so the request draws
/// on the plan the user already pays for. The CLI reports `provider: firstParty`
/// for these calls, which is how that is confirmed rather than assumed.
///
/// `AnthropicAdapter` in OAuth mode presents the same identity over HTTP and may
/// well land in the same lane, but that is account-dependent and unproven; this
/// path is the one that does not have to be verified.
///
/// The trade-off is that the CLI is a turn-based agent, not a chat endpoint:
/// tool definitions cannot be passed through, so this provider advertises no
/// tool support and requests needing tools route elsewhere.
public struct ClaudeCLIAdapter: ProviderAdapter {
    public let family: AdapterFamily = .claudeCLI
    public init() {}

    /// Arguments that make the CLI behave as a plain completion endpoint rather
    /// than a coding agent. Without them each call carries Claude Code's own
    /// system prompt, tool schemas and project context — about 27k tokens of
    /// overhead per request, versus roughly 300 with them.
    static func baseArguments(systemPrompt: String) -> [String] {
        [
            "--print",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--tools", "",                  // no built-in tools
            "--strict-mcp-config",          // no MCP servers
            "--setting-sources", "",        // no user/project/local settings, no CLAUDE.md
            "--no-session-persistence",     // a gateway call is not a saved session
            "--system-prompt", systemPrompt,
        ]
    }

    static let defaultSystemPrompt = "You are a helpful assistant."

    // MARK: - Locating and launching

    func executable(_ ctx: ProviderContext) throws -> URL {
        if let override = ctx.account.executablePathOverride?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw DerbyError(kind: .authentication,
                                 message: "No executable at \(url.path). Set the correct path to the `claude` CLI for \(ctx.account.name).")
            }
            return url
        }
        guard let found = ProcessRunner.locate("claude") else {
            throw DerbyError(kind: .authentication,
                             message: "Derby could not find the `claude` CLI. Install Claude Code, or set the path to it for \(ctx.account.name) in Providers.")
        }
        return found
    }

    /// A deliberately minimal environment.
    ///
    /// `ANTHROPIC_API_KEY` is removed: if it were present the CLI would bill the
    /// request to that key instead of the subscription, which is the very thing
    /// this provider exists to avoid.
    func environment(_ ctx: ProviderContext) -> [String: String] {
        var env = ProcessRunner.toolEnvironment(preferring: try? executable(ctx))

        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env.removeValue(forKey: "CLAUDE_CODE_SIMPLE")
        env["CLAUDE_CODE_ENTRYPOINT"] = "derby"
        // A per-account CLI home is what lets several Claude logins coexist.
        if let home = ctx.account.credentialHomeURL {
            env["CLAUDE_CONFIG_DIR"] = home.path
        }
        for (key, value) in ctx.account.extraHeaders { env[key] = value }
        return env
    }

    public func authenticate(_ ctx: ProviderContext) async throws -> ResolvedAuth {
        // Deliberately does not read the credential store.
        //
        // The CLI owns its own login, and Derby never needs the token on this
        // path. Reading Anthropic's Keychain item from Derby would raise a system
        // authorization dialog that blocks until answered — which hung every
        // request. If the CLI is not signed in it says so on stderr, and
        // `classify(stderr:)` turns that into an AUTHENTICATION failure.
        _ = try executable(ctx)
        return ResolvedAuth()
    }

    /// How long to wait for the CLI's first byte before concluding it is stuck.
    ///
    /// The CLI reads its own credential from the Keychain, and the first time it
    /// is launched by Derby macOS raises an authorization dialog for it. Until
    /// somebody answers that dialog the process simply sits there, so waiting out
    /// the full request deadline would turn a one-click prompt into a five-minute
    /// hang with no explanation.
    static let firstOutputTimeout: Double = 20

    static var keychainPromptError: DerbyError {
        DerbyError(
            kind: .authentication,
            message: "The Claude CLI started but produced nothing, which almost always means macOS is showing a Keychain prompt for it. Look for a dialog asking whether \"claude\" may use your keychain and choose Always Allow, then try again. Running `claude` once in Terminal also clears it.")
    }

    /// Asks the CLI whether it is signed in. Cheap, and costs no plan usage.
    func loginStatus(_ ctx: ProviderContext) async -> String? {
        guard let binary = try? executable(ctx) else { return nil }
        let lines = ProcessRunner.streamLines(executable: binary,
                                              arguments: ["login", "status"],
                                              environment: environment(ctx),
                                              currentDirectory: FileManager.default.temporaryDirectory)
        let channel = AsyncEventChannel<String>()
        let pump = Task {
            do {
                for try await line in lines { await channel.push(line) }
                await channel.finish()
            } catch { await channel.finish(throwing: error) }
        }
        defer { pump.cancel() }

        var output: [String] = []
        while true {
            let next = try? await channel.next(timeout: Self.firstOutputTimeout,
                                               timeoutMessage: "claude login status timed out")
            guard let line = next ?? nil else { break }
            output.append(line)
        }
        return output.isEmpty ? nil : output.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func listModels(_ ctx: ProviderContext) async throws -> [DiscoveredModel] {
        _ = try await authenticate(ctx)
        // The CLI exposes no model listing, so offer the aliases it accepts plus
        // whatever the metadata catalog knows about the current Claude family.
        let aliases = ["opus", "sonnet", "haiku"]
        return aliases.map { alias in
            let metadata = ModelCatalog.metadata(for: "claude-\(alias)", kind: ctx.account.kind)
            return DiscoveredModel(id: alias,
                                   displayName: "Latest \(alias.capitalized)",
                                   capabilities: Self.capabilities(metadata.capabilities),
                                   profile: ModelProfile(summary: "Resolved by the CLI to the newest \(alias).",
                                                         ownedBy: "anthropic"),
                                   pricing: .free)
        }
    }

    /// Tools and vision are not claimed: the CLI runs its own agent loop and
    /// accepts no caller-supplied tool schemas, so a request needing them must
    /// route to a different target rather than failing here.
    static func capabilities(_ base: ModelCapabilities) -> ModelCapabilities {
        var caps = base
        caps.flags = [.text, .streaming]
        if base.flags.contains(.reasoning) { caps.flags.insert(.reasoning) }
        caps.source = .discovered
        // Sampling parameters are not exposed by the CLI at all.
        caps.unsupportedParameters.formUnion([.temperature, .topP, .topK, .frequencyPenalty,
                                              .presencePenalty, .seed, .logprobs, .stop,
                                              .responseFormat, .toolChoice, .parallelToolCalls])
        return caps
    }

    public func capabilities(model: String, ctx: ProviderContext) -> ModelCapabilities {
        Self.capabilities(ModelCatalog.metadata(for: model, kind: ctx.account.kind).capabilities)
    }

    public func healthCheck(_ ctx: ProviderContext) async -> ConnectionTestResult {
        do {
            let binary = try executable(ctx)
            let status = await loginStatus(ctx)
            let signedIn = status?.lowercased().contains("logged in") ?? false
            guard signedIn else {
                return .failure(DerbyError(
                    kind: .authentication,
                    message: status?.isEmpty == false
                        ? "Claude Code reports: \(status!). Run `claude` in Terminal and sign in."
                        : "Claude Code is not signed in. Run `claude` in Terminal and sign in, then test again."))
            }
            let models = try await listModels(ctx)
            var details = ["Using \(binary.path).",
                           status ?? "Signed in.",
                           "Requests run through the CLI, so they draw on your plan limits rather than extra usage.",
                           "Tools and images are not available on this path — requests needing them route elsewhere."]
            if let home = ctx.account.credentialHomeURL {
                details.insert("Account directory: \(home.path).", at: 1)
            }
            return ConnectionTestResult(ok: true, headline: "Linked to Claude Code",
                                        details: details, discovered: models)
        } catch let error as DerbyError {
            return .failure(error)
        } catch {
            return .failure(DerbyError(kind: .unknown, message: error.localizedDescription))
        }
    }

    // MARK: - Prompt shaping

    /// Renders the conversation into one prompt.
    ///
    /// The CLI treats every input message as a *new turn* and answers each in
    /// sequence, so a conversation cannot be replayed as separate messages. A
    /// single-turn request is passed through untouched; only a genuine multi-turn
    /// conversation is rendered as a transcript.
    static func renderPrompt(_ messages: [CanonicalMessage]) -> String {
        let conversation = messages.filter { $0.role != .system && $0.role != .developer }
        let spoken = conversation.filter { !$0.joinedText.isEmpty || !$0.toolCalls.isEmpty }
        guard spoken.count > 1 else {
            return spoken.first?.joinedText ?? ""
        }
        var lines: [String] = []
        for (index, message) in spoken.enumerated() {
            let isLast = index == spoken.count - 1
            let label: String
            switch message.role {
            case .assistant: label = "Assistant"
            case .tool: label = "Tool result"
            default: label = "User"
            }
            if isLast, message.role == .user {
                lines.append("")
                lines.append("Respond to this latest message:")
                lines.append(message.joinedText)
            } else {
                lines.append("\(label): \(message.joinedText)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func systemPrompt(_ messages: [CanonicalMessage]) -> String {
        let texts = messages
            .filter { $0.role == .system || $0.role == .developer }
            .map(\.joinedText)
            .filter { !$0.isEmpty }
        return texts.isEmpty ? defaultSystemPrompt : texts.joined(separator: "\n\n")
    }

    func arguments(for request: CanonicalRequest, model: String, ctx: ProviderContext) -> [String] {
        var args = Self.baseArguments(systemPrompt: Self.systemPrompt(request.messages))
        args += ["--model", model]
        if let effort = request.reasoning?.effort,
           let level = ctx.modelCapabilities?.clampEffort(effort) ?? effort.rawValue as String? {
            args += ["--effort", level]
        }
        return args
    }

    // MARK: - Execute

    public func execute(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws -> CanonicalResponse {
        var accumulator = StreamAccumulator()
        for try await event in try await stream(request, model: model, ctx: ctx) {
            accumulator.ingest(event)
        }
        return accumulator.makeResponse(fallbackModel: model)
    }

    public func stream(_ request: CanonicalRequest, model: String, ctx: ProviderContext) async throws
        -> AsyncThrowingStream<CanonicalStreamEvent, Error> {
        _ = try await authenticate(ctx)
        let binary = try executable(ctx)
        let args = arguments(for: request, model: model, ctx: ctx) + [Self.renderPrompt(request.messages)]
        let env = environment(ctx)

        let lines = ProcessRunner.streamLines(executable: binary, arguments: args,
                                              environment: env,
                                              currentDirectory: FileManager.default.temporaryDirectory)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedStart = false
                var usage = CanonicalUsage.zero
                var finish = CanonicalFinishReason.stop
                var sawText = false

                // Read through a channel so a silent process can be abandoned
                // rather than holding the request open until its deadline.
                let channel = AsyncEventChannel<String>()
                let pump = Task {
                    do {
                        for try await line in lines { await channel.push(line) }
                        await channel.finish()
                    } catch { await channel.finish(throwing: error) }
                }
                defer { pump.cancel() }

                do {
                    var sawAnyOutput = false
                    while true {
                        let line: String?
                        do {
                            line = try await channel.next(
                                timeout: sawAnyOutput ? ctx.attemptTimeout : Self.firstOutputTimeout,
                                timeoutMessage: "the Claude CLI produced no output")
                        } catch let error as DerbyError where error.kind == .timeout && !sawAnyOutput {
                            throw Self.keychainPromptError
                        }
                        guard let line else { break }
                        sawAnyOutput = true
                        guard let event = JSONValue.parse(line) else { continue }
                        switch event["type"]?.stringValue {
                        case "system":
                            if !emittedStart {
                                emittedStart = true
                                continuation.yield(.start(id: event["session_id"]?.stringValue ?? IDGenerator.requestID(),
                                                          model: event["model"]?.stringValue ?? model))
                            }

                        case "stream_event":
                            // The CLI forwards Anthropic's own SSE events, so the
                            // same shapes the HTTP adapter already understands.
                            guard let inner = event["event"] else { break }
                            switch inner["type"]?.stringValue {
                            case "content_block_delta":
                                let delta = inner["delta"] ?? .null
                                if let text = delta["text"]?.stringValue, !text.isEmpty {
                                    sawText = true
                                    continuation.yield(.textDelta(text))
                                }
                                if let thinking = delta["thinking"]?.stringValue, !thinking.isEmpty {
                                    continuation.yield(.reasoningDelta(thinking))
                                }
                            case "message_delta":
                                if let reason = inner["delta"]?["stop_reason"]?.stringValue {
                                    finish = Self.mapStop(reason)
                                }
                            default: break
                            }

                        case "assistant":
                            // Fallback for builds that do not emit partial events:
                            // take the complete message if no deltas arrived.
                            if !sawText, let blocks = event["message"]?["content"]?.arrayValue {
                                for block in blocks where block["type"]?.stringValue == "text" {
                                    if let text = block["text"]?.stringValue, !text.isEmpty {
                                        sawText = true
                                        continuation.yield(.textDelta(text))
                                    }
                                }
                            }

                        case "result":
                            if event["is_error"]?.boolValue == true {
                                throw Self.error(from: event)
                            }
                            usage = Self.parseUsage(event["usage"] ?? .null)
                            if let reason = event["stop_reason"]?.stringValue {
                                finish = Self.mapStop(reason)
                            }

                        default:
                            break
                        }
                    }
                    if !usage.isEmpty { continuation.yield(.usage(usage)) }
                    continuation.yield(.finish(finish))
                    continuation.finish()
                } catch let failure as ProcessRunner.Failure {
                    continuation.finish(throwing: Self.classify(stderr: failure.description))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Parsing

    static func parseUsage(_ usage: JSONValue) -> CanonicalUsage {
        guard !usage.isNull else { return .zero }
        return CanonicalUsage(
            inputTokens: usage["input_tokens"]?.intValue ?? 0,
            outputTokens: usage["output_tokens"]?.intValue ?? 0,
            cachedInputTokens: usage["cache_read_input_tokens"]?.intValue ?? 0,
            cacheWriteTokens: usage["cache_creation_input_tokens"]?.intValue ?? 0,
            reasoningTokens: usage["output_tokens_details"]?["thinking_tokens"]?.intValue ?? 0)
    }

    /// Plan utilization, expressed in the shape the router already scores on.
    ///
    /// The CLI reports how much of the rolling five-hour and seven-day windows
    /// has been consumed, which is exactly the signal needed to route away from a
    /// subscription that is nearly spent.
    public static func rateLimit(from event: JSONValue) -> RateLimitSnapshot? {
        guard let info = event["rate_limit_info"], !info.isNull else { return nil }
        let windows = info["unifiedWindows"] ?? .null
        var worst: Double = 0
        var resetsAt: Double?
        for key in ["five_hour", "seven_day"] {
            guard let window = windows[key], !window.isNull,
                  let utilization = window["utilization"]?.doubleValue else { continue }
            if utilization >= worst {
                worst = utilization
                resetsAt = window["resetsAt"]?.doubleValue
            }
        }
        guard worst > 0 || info["status"]?.stringValue != nil else { return nil }

        // Scaled to a nominal 1000 "requests" so the existing pressure and
        // exhaustion logic applies unchanged.
        let limit = 1000
        let remaining = Int((1 - min(1, max(0, worst))) * Double(limit))
        var snapshot = RateLimitSnapshot(requestsLimit: limit,
                                         requestsRemaining: remaining,
                                         observedAt: Date())
        if let resetsAt {
            snapshot.requestsResetSeconds = max(0, resetsAt - Date().timeIntervalSince1970)
        }
        if info["status"]?.stringValue == "rejected" || remaining <= 0 {
            snapshot.retryAfterSeconds = snapshot.requestsResetSeconds ?? 300
        }
        return snapshot
    }

    public func rateLimitSnapshot(from headers: [String: String]) -> RateLimitSnapshot? { nil }

    static func mapStop(_ reason: String?) -> CanonicalFinishReason {
        switch reason {
        case "end_turn", "stop_sequence", nil: return .stop
        case "max_tokens": return .length
        case "tool_use": return .toolCalls
        case "refusal": return .contentFilter
        default: return .other
        }
    }

    static func error(from result: JSONValue) -> DerbyError {
        let message = result["result"]?.stringValue
            ?? result["error"]?.stringValue
            ?? "The Claude CLI reported an error."
        return classify(stderr: message)
    }

    /// Maps the CLI's own failure text onto Derby's taxonomy.
    static func classify(stderr: String) -> DerbyError {
        let text = SecretRedactor.redact(stderr)
        let lower = text.lowercased()

        if lower.contains("not logged in") || lower.contains("please run") && lower.contains("login")
            || lower.contains("authentication") || lower.contains("unauthorized") {
            return DerbyError(kind: .authentication,
                              message: "The Claude CLI is not signed in. Run `claude` in Terminal and sign in, then try again.",
                              detail: text)
        }
        if lower.contains("usage limit") || lower.contains("rate limit")
            || lower.contains("plan limit") || lower.contains("resets at") {
            return DerbyError(kind: .quotaExhausted,
                              message: "This Claude plan's usage limit has been reached. Derby will route elsewhere until it resets.",
                              detail: text)
        }
        if lower.contains("overloaded") || lower.contains("capacity") {
            return DerbyError(kind: .providerDown, message: "Anthropic is overloaded.", detail: text)
        }
        if lower.contains("context") && (lower.contains("too long") || lower.contains("exceed")) {
            return DerbyError(kind: .contextOverflow, message: text)
        }
        if lower.contains("command not found") || lower.contains("no such file") {
            return DerbyError(kind: .authentication,
                              message: "The `claude` CLI could not be run. Check its path in Providers.",
                              detail: text)
        }
        return DerbyError(kind: .transient,
                          message: text.isEmpty ? "The Claude CLI failed." : text)
    }

    public func classifyError(status: Int, headers: [String: String], body: Data, model: String) -> DerbyError {
        Self.classify(stderr: String(data: body, encoding: .utf8) ?? "")
    }
}
