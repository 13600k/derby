import Foundation

/// Where a CLI credential was read from. Typed rather than a display string,
/// because a refresh must write back to the *same* store — updating a stale copy
/// while the live one keeps a superseded refresh token would log the user out of
/// their own CLI.
public enum CredentialOrigin: Sendable, Equatable {
    case file(URL)
    case keychain(service: String, account: String?)

    public var describing: String {
        switch self {
        case .file(let url): return url.path
        case .keychain(let service, _): return "Keychain: \(service)"
        }
    }
}

/// An OAuth credential belonging to an already-authenticated local CLI.
public struct CLICredential: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    /// ChatGPT/Codex requires the account id as a separate header.
    public var accountID: String?
    /// Qwen returns a per-account API host.
    public var resourceURL: String?
    /// Who this credential belongs to — e.g. "you@example.com · Plus". Shown so
    /// several accounts of the same service can be told apart.
    public var accountLabel: String?
    /// Which store it came from — used for display *and* for write-back.
    public var source: CredentialOrigin?
    /// Human-readable form of `source`.
    public var origin: String { source?.describing ?? "unknown" }

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                accountID: String? = nil, resourceURL: String? = nil,
                accountLabel: String? = nil, source: CredentialOrigin? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.resourceURL = resourceURL
        self.accountLabel = accountLabel
        self.source = source
    }

    /// Treat a token as expired slightly early so a request never races expiry.
    public func isExpired(skew: TimeInterval = 60) -> Bool {
        guard let e = expiresAt else { return false }
        return Date().addingTimeInterval(skew) >= e
    }
    public var expiresInDescription: String {
        guard let e = expiresAt else { return "no expiry recorded" }
        let d = e.timeIntervalSinceNow
        if d <= 0 { return "expired" }
        if d < 3600 { return "expires in \(Int(d / 60)) min" }
        if d < 86400 { return "expires in \(Int(d / 3600)) h" }
        return "expires in \(Int(d / 86400)) d"
    }
}

/// Reads credentials from local CLI credential stores.
///
/// Derby is a *read-only* consumer by default: it never writes to another
/// tool's credential file unless the user opts into managed refresh, because
/// refreshing rotates the refresh token and would otherwise silently log the
/// user out of their CLI.
public enum CLICredentialReader {

    public static func home() -> URL {
        // NSHomeDirectory() is container-relative under App Sandbox; Derby ships
        // unsandboxed, but resolve via passwd to be certain we get the real home.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// The directory a CLI keeps its state in, by default.
    ///
    /// Each of these CLIs supports relocating that directory — `CODEX_HOME` for
    /// Codex, `CLAUDE_CONFIG_DIR` for Claude Code — which is what makes several
    /// simultaneous logins to the *same* service possible. Derby points an
    /// account at one of those directories.
    public static func defaultHome(for source: CLICredentialSource) -> URL {
        switch source {
        case .claudeCode: return home().appendingPathComponent(".claude")
        case .codexCLI:   return home().appendingPathComponent(".codex")
        case .geminiCLI:  return home().appendingPathComponent(".gemini")
        case .qwenCLI:    return home().appendingPathComponent(".qwen")
        }
    }

    /// The credential file within a home directory.
    public static func credentialFilename(for source: CLICredentialSource) -> String {
        switch source {
        case .claudeCode: return ".credentials.json"
        case .codexCLI:   return "auth.json"
        case .geminiCLI, .qwenCLI: return "oauth_creds.json"
        }
    }

    public static func credentialPath(for source: CLICredentialSource, home overrideHome: URL? = nil) -> URL {
        (overrideHome ?? defaultHome(for: source))
            .appendingPathComponent(credentialFilename(for: source))
    }

    /// The environment variable a user sets to isolate this CLI's state.
    public static func homeEnvironmentVariable(for source: CLICredentialSource) -> String? {
        switch source {
        case .codexCLI: return "CODEX_HOME"
        case .claudeCode: return "CLAUDE_CONFIG_DIR"
        case .geminiCLI, .qwenCLI: return nil
        }
    }

    /// True when the CLI appears to be installed and logged in.
    public static func isAvailable(_ source: CLICredentialSource, home: URL? = nil) -> Bool {
        (try? read(source, home: home)) != nil
    }

    public static func read(_ source: CLICredentialSource, home: URL? = nil) throws -> CLICredential {
        switch source {
        case .claudeCode: return try readClaudeCode(home: home)
        case .codexCLI:   return try readCodex(home: home)
        case .geminiCLI:  return try readGemini(home: home)
        case .qwenCLI:    return try readQwen(home: home)
        }
    }

    private static func loadJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func notLoggedIn(_ source: CLICredentialSource, home: URL? = nil) -> DerbyError {
        guard let home, let variable = homeEnvironmentVariable(for: source) else {
            return DerbyError(kind: .authentication,
                              message: "\(source.displayName) is not signed in. Run `\(source.loginCommand)` in Terminal, then test the connection again.")
        }
        return DerbyError(kind: .authentication,
                          message: "No \(source.displayName) session in \(home.path). Run `mkdir -p \(home.path) && \(variable)=\(home.path) \(source.loginCommand)` in Terminal to sign this account in separately, then test the connection again.")
    }

    // MARK: - Claude Code

    public static let claudeCodeKeychainService = "Claude Code-credentials"

    /// Claude Code keeps credentials in the Keychain on macOS, but a plaintext
    /// `~/.claude/.credentials.json` from an older install (or another platform)
    /// is often left behind. Reading the file first meant picking up a stale,
    /// long-expired token and then trying to refresh with a superseded refresh
    /// token, which the server rejects with HTTP 400.
    ///
    /// Both stores are read and the one that expires latest wins.
    private static func readClaudeCode(home: URL?) throws -> CLICredential {
        var candidates: [CLICredential] = []

        let path = credentialPath(for: .claudeCode, home: home)
        if let obj = loadJSON(path), let cred = parseClaudeCode(obj, source: .file(path)) {
            candidates.append(cred)
        }
        // The Keychain holds a single item for the default install. An account
        // pointed at its own config directory must not fall back to it, or two
        // separate logins would collapse into the same credential.
        if home == nil,
           let raw = KeychainSecretStore.readForeignGenericPassword(service: claudeCodeKeychainService),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cred = parseClaudeCode(obj, source: .keychain(service: claudeCodeKeychainService, account: nil)) {
            candidates.append(cred)
        }

        guard let best = freshest(of: candidates) else { throw notLoggedIn(.claudeCode, home: home) }
        return best
    }

    /// Of several copies of the same credential, the one that expires latest is
    /// the live one. A copy with no recorded expiry loses to any that has one.
    public static func freshest(of candidates: [CLICredential]) -> CLICredential? {
        candidates.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) })
    }

    private static func parseClaudeCode(_ obj: [String: Any], source: CredentialOrigin) -> CLICredential? {
        guard let o = obj["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date?
        if let ms = o["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        else if let ms = o["expiresAt"] as? Int { expires = Date(timeIntervalSince1970: Double(ms) / 1000) }
        return CLICredential(accessToken: token,
                             refreshToken: o["refreshToken"] as? String,
                             expiresAt: expires,
                             source: source)
    }

    // MARK: - Codex / ChatGPT

    private static func readCodex(home: URL?) throws -> CLICredential {
        let path = credentialPath(for: .codexCLI, home: home)
        guard let obj = loadJSON(path) else { throw notLoggedIn(.codexCLI, home: home) }
        guard let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            // An API-key-mode codex install is not a subscription credential.
            if let key = obj["OPENAI_API_KEY"] as? String, !key.isEmpty {
                throw DerbyError(kind: .authentication,
                                 message: "The Codex CLI is configured with an API key, not a ChatGPT subscription. Add an OpenAI API provider instead.")
            }
            throw notLoggedIn(.codexCLI, home: home)
        }
        let idToken = tokens["id_token"] as? String
        return CLICredential(accessToken: access,
                             refreshToken: tokens["refresh_token"] as? String,
                             expiresAt: JWT.expiry(of: access),
                             accountID: tokens["account_id"] as? String ?? JWT.chatGPTAccountID(of: access),
                             accountLabel: idToken.flatMap { JWT.chatGPTAccountLabel(of: $0) },
                             source: .file(path))
    }

    // MARK: - Gemini CLI

    private static func readGemini(home: URL?) throws -> CLICredential {
        let path = credentialPath(for: .geminiCLI, home: home)
        guard let obj = loadJSON(path), let access = obj["access_token"] as? String, !access.isEmpty else {
            throw notLoggedIn(.geminiCLI, home: home)
        }
        var expires: Date?
        if let ms = obj["expiry_date"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        var project: String?
        // Sibling file in the same home, so an isolated Gemini config directory
        // resolves its own project rather than the default install's.
        let geminiHome = home ?? defaultHome(for: .geminiCLI)
        if let acc = loadJSON(geminiHome.appendingPathComponent("google_accounts.json")) {
            project = acc["projectId"] as? String ?? (acc["active"] as? [String: Any])?["projectId"] as? String
        }
        return CLICredential(accessToken: access,
                             refreshToken: obj["refresh_token"] as? String,
                             expiresAt: expires,
                             accountID: project,
                             source: .file(path))
    }

    // MARK: - Qwen CLI

    private static func readQwen(home: URL?) throws -> CLICredential {
        let path = credentialPath(for: .qwenCLI, home: home)
        guard let obj = loadJSON(path), let access = obj["access_token"] as? String, !access.isEmpty else {
            throw notLoggedIn(.qwenCLI, home: home)
        }
        var expires: Date?
        if let ms = obj["expiry_date"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        var resource = obj["resource_url"] as? String
        if let r = resource, !r.hasPrefix("http") { resource = "https://\(r)" }
        return CLICredential(accessToken: access,
                             refreshToken: obj["refresh_token"] as? String,
                             expiresAt: expires,
                             resourceURL: resource,
                             source: .file(path))
    }

    // MARK: - Managed refresh (opt-in)

    /// OAuth client ids published by each CLI's public client. Refresh is only
    /// attempted when the user enables it for the account.
    private static func refreshEndpoint(for source: CLICredentialSource) -> (url: URL, clientID: String)? {
        switch source {
        case .claudeCode:
            return (URL(string: "https://console.anthropic.com/v1/oauth/token")!,
                    "9d1c250a-e61b-8d94-be2f-a0c5e4f5b4f2")
        case .codexCLI:
            return (URL(string: "https://auth.openai.com/oauth/token")!,
                    "app_EMoamEEZ73f0CkXaXp7hrann")
        case .geminiCLI, .qwenCLI:
            return nil   // not implemented; these CLIs refresh on their own schedule
        }
    }

    /// Exchanges the refresh token for a fresh access token and writes the
    /// rotated credentials back to the CLI's own store, so the user's CLI keeps
    /// working. Throws if refresh is unsupported or the token is rejected.
    public static func refresh(_ source: CLICredentialSource, current: CLICredential,
                               home: URL? = nil) async throws -> CLICredential {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw DerbyError(kind: .authentication,
                             message: "No refresh token available for \(source.displayName). Run `\(source.loginCommand)`.")
        }
        guard let ep = refreshEndpoint(for: source) else {
            throw DerbyError(kind: .authentication,
                             message: "Derby cannot refresh \(source.displayName) tokens. Run `\(source.loginCommand)` to renew the session.")
        }
        var req = URLRequest(url: ep.url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["grant_type": "refresh_token",
                                   "refresh_token": refreshToken,
                                   "client_id": ep.clientID]
        if source == .codexCLI { body["scope"] = "openid profile email" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            // A rejected refresh usually means the token Derby held had already
            // been superseded — very often because the CLI itself refreshed, or
            // the user signed in again, since Derby last read it. Re-read before
            // giving up: the store may already hold a perfectly good session.
            if let fresh = try? read(source, home: home),
               fresh.accessToken != current.accessToken,
               !fresh.isExpired() {
                return fresh
            }
            let body = SecretRedactor.redact(String(data: data.prefix(400), encoding: .utf8) ?? "")
            let hint = status == 400 || status == 401
                ? "The stored refresh token was rejected, which usually means it had already been used or replaced."
                : "The authorization server rejected the request."
            throw DerbyError(kind: .authentication,
                             message: "Could not refresh the \(source.displayName) session (HTTP \(status)). \(hint) Run `\(source.loginCommand)` in Terminal, then test the connection again.",
                             providerStatus: status,
                             detail: body.isEmpty ? nil : body)
        }
        var updated = current
        updated.accessToken = access
        if let rt = obj["refresh_token"] as? String, !rt.isEmpty { updated.refreshToken = rt }
        if let expiresIn = obj["expires_in"] as? Double {
            updated.expiresAt = Date().addingTimeInterval(expiresIn)
        } else {
            updated.expiresAt = JWT.expiry(of: access)
        }
        do {
            try writeBack(source, credential: updated, home: home)
        } catch {
            // The token is valid and usable; only the CLI's copy is now behind.
            // Say so rather than failing the request.
            DerbyLog.warn("credentials", "\(source.displayName): \(error.localizedDescription)")
        }
        return updated
    }

    /// Keeps the CLI's own store in sync after a rotation.
    ///
    /// This must target the store the credential was *read* from. Refreshing
    /// rotates the refresh token, so updating a stale copy while the live store
    /// keeps the superseded one would break the user's CLI on its next refresh —
    /// the precise outcome Derby's read-only default exists to avoid.
    private static func writeBack(_ source: CLICredentialSource, credential: CLICredential,
                                  home: URL? = nil) throws {
        if case .keychain(let service, let account) = credential.source {
            try writeBackToKeychain(service: service, account: account,
                                    source: source, credential: credential)
            return
        }
        let path = credentialPath(for: source, home: home)
        guard var obj = loadJSON(path) else { return }
        switch source {
        case .claudeCode:
            var o = (obj["claudeAiOauth"] as? [String: Any]) ?? [:]
            o["accessToken"] = credential.accessToken
            if let rt = credential.refreshToken { o["refreshToken"] = rt }
            if let e = credential.expiresAt { o["expiresAt"] = Int(e.timeIntervalSince1970 * 1000) }
            obj["claudeAiOauth"] = o
        case .codexCLI:
            var t = (obj["tokens"] as? [String: Any]) ?? [:]
            t["access_token"] = credential.accessToken
            if let rt = credential.refreshToken { t["refresh_token"] = rt }
            obj["tokens"] = t
            obj["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        case .geminiCLI, .qwenCLI:
            obj["access_token"] = credential.accessToken
            if let rt = credential.refreshToken { obj["refresh_token"] = rt }
            if let e = credential.expiresAt { obj["expiry_date"] = Int(e.timeIntervalSince1970 * 1000) }
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        let tmp = path.appendingPathExtension("derby-tmp")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
    }

    /// Rewrites a Keychain-held credential blob, preserving every field the CLI
    /// stores that Derby does not model.
    private static func writeBackToKeychain(service: String, account: String?,
                                            source: CLICredentialSource,
                                            credential: CLICredential) throws {
        guard let raw = KeychainSecretStore.readForeignGenericPassword(service: service, account: account),
              let data = raw.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DerbyError(kind: .authentication,
                             message: "Derby refreshed the \(source.displayName) session but could not read its Keychain entry to save the new token.")
        }
        switch source {
        case .claudeCode:
            var o = (obj["claudeAiOauth"] as? [String: Any]) ?? [:]
            o["accessToken"] = credential.accessToken
            if let rt = credential.refreshToken { o["refreshToken"] = rt }
            if let e = credential.expiresAt { o["expiresAt"] = Int(e.timeIntervalSince1970 * 1000) }
            obj["claudeAiOauth"] = o
        case .codexCLI:
            var t = (obj["tokens"] as? [String: Any]) ?? [:]
            t["access_token"] = credential.accessToken
            if let rt = credential.refreshToken { t["refresh_token"] = rt }
            obj["tokens"] = t
            obj["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        case .geminiCLI, .qwenCLI:
            obj["access_token"] = credential.accessToken
            if let rt = credential.refreshToken { obj["refresh_token"] = rt }
            if let e = credential.expiresAt { obj["expiry_date"] = Int(e.timeIntervalSince1970 * 1000) }
        }
        let updated = try JSONSerialization.data(withJSONObject: obj)
        guard let text = String(data: updated, encoding: .utf8),
              KeychainSecretStore.updateForeignGenericPassword(service: service, account: account, value: text) else {
            throw DerbyError(kind: .authentication,
                             message: "Derby refreshed the \(source.displayName) session but could not write the new token back to the Keychain. Run `\(source.loginCommand)` if the CLI stops working.")
        }
    }
}

/// Minimal JWT claim reader — used only to learn a token's expiry, never to
/// validate it (the provider does that).
public enum JWT {
    public static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                  .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
    public static func expiry(of token: String) -> Date? {
        guard let c = claims(of: token), let exp = c["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
    /// Codex embeds the ChatGPT account id inside a namespaced claim.
    public static func chatGPTAccountID(of token: String) -> String? {
        guard let c = claims(of: token) else { return nil }
        for (k, v) in c where k.hasSuffix("auth") {
            if let o = v as? [String: Any], let id = o["chatgpt_account_id"] as? String { return id }
        }
        return c["chatgpt_account_id"] as? String
    }

    /// A human label for a ChatGPT login, from the id token's profile claims:
    /// the account's email and, when present, its plan.
    public static func chatGPTAccountLabel(of token: String) -> String? {
        guard let c = claims(of: token) else { return nil }
        var email: String?
        var plan: String?
        for (key, value) in c {
            guard let object = value as? [String: Any] else { continue }
            if key.hasSuffix("profile") {
                email = object["email"] as? String ?? object["name"] as? String
            }
            if key.hasSuffix("auth") {
                plan = object["chatgpt_plan_type"] as? String
            }
        }
        guard let email else { return plan?.capitalized }
        guard let plan, !plan.isEmpty else { return email }
        return "\(email) · \(plan.capitalized)"
    }
}
