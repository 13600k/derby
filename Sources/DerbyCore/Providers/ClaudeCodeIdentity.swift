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
/// Anthropic's billing classifier reads. Collected here rather than inline in
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
