import Foundation

/// The wire identity Claude Code presents to `api.anthropic.com`.
///
/// Anthropic routes a subscription OAuth token by *who is calling*, not by the
/// token alone. Four things carry that signal, and they are only meaningful
/// together: the `oauth-2025-04-20` beta that makes a bearer token acceptable at
/// all, the `claude-code-20250219` beta that names the caller, a `user-agent`
/// and `x-app` pair matching the CLI, and a first system block identifying the
/// assistant as Claude Code.
///
/// Derby previously sent only the first and the last. That is accepted, but it
/// presents as a bare OAuth client rather than as the CLI — which is both the
/// documented cause of intermittent HTTP 500s on this path and the distinction
/// Anthropic's billing classifier reads. So are the tool names a request
/// declares (`ToolNames`). Collected here rather than inline in
/// `AnthropicAdapter` so the whole fingerprint is one list that can be reviewed,
/// tested, and updated as a unit when it drifts.
public enum ClaudeCodeIdentity {
    /// Required as the first system block; the token is rejected without it.
    public static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Sent only with an OAuth credential — an API key with these is a caller
    /// claiming to be something it is not, and gains nothing.
    public static let oauthBetas = ["claude-code-20250219", "oauth-2025-04-20"]

    /// Flags the CLI carries on every call. GA on current Claude models and a
    /// harmless no-op there, but part of what the request looks like.
    public static let sessionBetas = ["interleaved-thinking-2025-05-14",
                                      "fine-grained-tool-streaming-2025-05-14"]

    /// Deliberately absent: `context-1m-2025-08-07`. An account without the
    /// long-context beta answers HTTP 400 to *every* request carrying it, so
    /// claiming it here would break short calls to buy a window most
    /// subscriptions cannot use anyway.
    public static let withheldBetas = ["context-1m-2025-08-07"]

    public static let appHeader = "cli"

    public static func userAgent(version: String) -> String {
        "claude-code/\(version) (external, cli)"
    }

    /// Used when the CLI is not installed to be asked.
    ///
    /// Anthropic rejects an OAuth request whose declared version trails the
    /// current release too far, so this constant goes stale on its own and the
    /// installed CLI is always preferred over it.
    public static let fallbackVersion = "2.1.259"

    /// The complete header set for an OAuth call, minus the bearer token itself.
    ///
    /// Pure and version-injected so the identity can be asserted in tests without
    /// starting a process.
    public static func headers(version: String) -> [String: String] {
        [
            "anthropic-beta": (sessionBetas + oauthBetas).joined(separator: ","),
            "user-agent": userAgent(version: version),
            "x-app": appHeader,
        ]
    }

    /// Tool names as a subscription request carries them.
    ///
    /// Claude Code's own tools reach the model under its names, and every tool
    /// it takes from elsewhere as `mcp__<server>__<tool>`. Anthropic reads the
    /// tool list too: a bare name such as `read_file`, or a single-underscore
    /// `mcp_read_file`, marks the caller as a third-party app, and a third-party
    /// app is billed to extra usage rather than the plan. Hermes Agent found
    /// this empirically and sends every tool as `mcp__<name>` (its GH-25255);
    /// Derby does the same, and maps each name back before the client sees it.
    ///
    /// Built from the request's own tools, so the mapping is exact in both
    /// directions, and a pure function of the names in order, so the tool list
    /// is byte-identical turn after turn and the prompt cache still matches.
    public struct ToolNames: Sendable, Equatable {
        public static let prefix = "mcp__"
        /// Anthropic's ceiling on a tool name.
        static let maxLength = 64

        private let toWire: [String: String]
        private let toClient: [String: String]
        private let renames: Bool

        /// Every name passes through as it is — what any non-subscription caller gets.
        public static let unchanged = ToolNames(toWire: [:], toClient: [:], renames: false)

        private init(toWire: [String: String], toClient: [String: String], renames: Bool) {
            self.toWire = toWire; self.toClient = toClient; self.renames = renames
        }

        public init<Names: Sequence>(_ clientNames: Names) where Names.Element == String {
            var toWire: [String: String] = [:], toClient: [String: String] = [:]
            for name in clientNames where toWire[name] == nil {
                var wire = Self.fitted(Self.wireForm(name))
                // `read_file` and `mcp_read_file` both become `mcp__read_file`;
                // the later one keeps its whole name, so the map still inverts.
                var attempt = 1
                while toClient[wire] != nil {
                    wire = Self.fitted(Self.prefix + name + (attempt == 1 ? "" : "_\(attempt)"))
                    attempt += 1
                }
                toWire[name] = wire
                toClient[wire] = name
            }
            self.init(toWire: toWire, toClient: toClient, renames: true)
        }

        /// The name to send for a tool the client named `name`.
        public func wire(_ name: String) -> String {
            guard renames else { return name }
            return toWire[name] ?? Self.fitted(Self.wireForm(name))
        }

        /// The client's name for a tool the model called `name`. A prefixed name
        /// this request never offered loses the prefix, as it would have had.
        public func client(_ name: String) -> String {
            guard renames else { return name }
            if let original = toClient[name] { return original }
            return name.hasPrefix(Self.prefix) ? String(name.dropFirst(Self.prefix.count)) : name
        }

        /// `mcp__x` stays; `mcp_x` and a bare `x` both become `mcp__x`.
        static func wireForm(_ name: String) -> String {
            if name.hasPrefix(prefix) { return name }
            if name.hasPrefix("mcp_") { return prefix + name.dropFirst("mcp_".count) }
            return prefix + name
        }

        /// Shortens a name past the limit to a prefix of it plus a hash of the
        /// whole, which stays unique and the same every time it is computed.
        static func fitted(_ name: String) -> String {
            guard name.count > maxLength else { return name }
            var hash: UInt32 = 2_166_136_261
            for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            let suffix = "_" + String(format: "%08x", hash)
            return String(name.prefix(maxLength - suffix.count)) + suffix
        }
    }
}

/// The installed Claude Code version, detected once per process.
///
/// Kept off the launch path: the first OAuth request pays for the subprocess and
/// every later one reads the cache. A version that changes only when the user
/// upgrades the CLI does not justify spawning a process per request, and the
/// probe is bounded so a wedged binary cannot hold a request open.
public actor ClaudeCodeVersion {
    public static let shared = ClaudeCodeVersion()

    /// Generous for printing a version string, short enough that failing to get
    /// one costs a request almost nothing — the fallback is then used.
    static let probeTimeout: Double = 5

    private var resolved: String?
    private var inFlight: Task<String, Never>?

    init() {}

    /// The version to declare, detected on first use.
    ///
    /// Never throws: an undetectable version is a reason to fall back, not to
    /// fail a request that would otherwise succeed.
    public func current() async -> String {
        if let resolved { return resolved }
        if let inFlight { return await inFlight.value }
        let task = Task<String, Never> {
            await Self.installedVersion() ?? ClaudeCodeIdentity.fallbackVersion
        }
        inFlight = task
        let value = await task.value
        inFlight = nil
        resolved = value
        return value
    }

    /// Seeds the cache so tests never start a process.
    func seed(_ version: String) { resolved = version }

    /// `claude --version` prints `2.1.259 (Claude Code)`; the leading token is
    /// the version. Anything that is not digit-led is treated as no answer.
    static func parse(_ line: String) -> String? {
        guard let first = line.split(separator: " ").first.map(String.init),
              first.first?.isNumber == true else { return nil }
        return first
    }

    static func installedVersion() async -> String? {
        guard let binary = ProcessRunner.locate("claude") else { return nil }
        let lines = ProcessRunner.streamLines(executable: binary,
                                              arguments: ["--version"],
                                              environment: ProcessRunner.toolEnvironment(preferring: binary),
                                              currentDirectory: FileManager.default.temporaryDirectory)
        let channel = AsyncEventChannel<String>()
        let pump = Task {
            do {
                for try await line in lines { await channel.push(line) }
                await channel.finish()
            } catch { await channel.finish(throwing: error) }
        }
        defer { pump.cancel() }

        // One line is all that is wanted; the deadline resolves the same
        // continuation rather than racing a sleep against it.
        let first = try? await channel.next(timeout: probeTimeout,
                                            timeoutMessage: "claude --version produced no output")
        guard let line = first ?? nil else { return nil }
        return parse(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
