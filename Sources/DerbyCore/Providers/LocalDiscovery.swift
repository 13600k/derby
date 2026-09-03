import Foundation

/// Probes well-known localhost ports for OpenAI-compatible model servers so the
/// UI can offer one-click setup.
public enum LocalDiscovery {
    public struct Finding: Sendable, Identifiable, Hashable {
        public var id: String { "\(kind.rawValue)-\(baseURL)" }
        public var kind: ProviderKind
        public var baseURL: String
        public var models: [String]
        public var note: String
    }

    /// (kind, base URL) pairs Derby checks. Ordered so the most distinctive
    /// server for a shared port is probed first.
    public static let candidates: [(ProviderKind, String)] = [
        (.ollama, "http://127.0.0.1:11434/v1"),
        (.lmStudio, "http://127.0.0.1:1234/v1"),
        (.vllm, "http://127.0.0.1:8000/v1"),
        (.sglang, "http://127.0.0.1:30000/v1"),
        (.llamaCpp, "http://127.0.0.1:8080/v1"),
        (.localai, "http://127.0.0.1:8081/v1"),
    ]

    public static func scan(transport: any HTTPTransport = URLSessionTransport.shared,
                            timeout: Double = 1.5) async -> [Finding] {
        await withTaskGroup(of: Finding?.self) { group in
            for (kind, base) in candidates {
                group.addTask {
                    await probe(kind: kind, baseURL: base, transport: transport, timeout: timeout)
                }
            }
            var out: [Finding] = []
            for await f in group { if let f { out.append(f) } }
            return out.sorted { $0.kind.displayName < $1.kind.displayName }
        }
    }

    public static func probe(kind: ProviderKind, baseURL: String,
                             transport: any HTTPTransport = URLSessionTransport.shared,
                             timeout: Double = 1.5) async -> Finding? {
        guard let url = URL(string: baseURL.trimmedTrailingSlash + "/models") else { return nil }
        let req = OutboundRequest(url: url, method: "GET", timeout: timeout)
        guard let resp = try? await transport.send(req), (200..<300).contains(resp.status) else { return nil }
        let ids = (resp.bodyJSON?["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        let note = ids.isEmpty
            ? "Reachable, but no models are loaded yet."
            : "\(ids.count) model\(ids.count == 1 ? "" : "s") available."
        return Finding(kind: kind, baseURL: baseURL, models: ids, note: note)
    }

    /// Which subscription CLIs are signed in on this machine.
    public struct SubscriptionFinding: Sendable, Identifiable, Hashable {
        public var id: String { source.rawValue }
        public var source: CLICredentialSource
        public var kind: ProviderKind
        public var available: Bool
        public var detail: String
    }

    /// An additional, isolated CLI state directory holding its own login.
    public struct AlternateHome: Sendable, Identifiable, Hashable {
        public var id: String { path }
        public var source: CLICredentialSource
        public var path: String
        public var isSignedIn: Bool
        public var accountLabel: String?
        public var isDefault: Bool
    }

    /// Finds CLI homes beyond the default one — the mechanism behind running
    /// several accounts of the same service at once (`CODEX_HOME`,
    /// `CLAUDE_CONFIG_DIR`). Sibling directories of the default home are scanned,
    /// e.g. `~/.codex-work` next to `~/.codex`.
    public static func alternateHomes(for source: CLICredentialSource) -> [AlternateHome] {
        let defaultHome = CLICredentialReader.defaultHome(for: source)
        let parent = defaultHome.deletingLastPathComponent()
        let prefix = defaultHome.lastPathComponent            // e.g. ".codex"

        var candidates: [URL] = [defaultHome]
        if let children = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            candidates += children.filter { $0.lastPathComponent.hasPrefix(prefix) }
        }
        // `skipsHiddenFiles` hides dot-directories, which is exactly what these
        // are, so enumerate the parent directly as well.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            candidates += names
                .filter { $0.hasPrefix(prefix) && $0 != prefix }
                .map { parent.appendingPathComponent($0) }
        }

        var seen = Set<String>()
        var out: [AlternateHome] = []
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let isDefault = path == defaultHome.standardizedFileURL.path
            let credential = try? CLICredentialReader.read(source, home: isDefault ? nil : url)
            out.append(AlternateHome(source: source, path: path,
                                     isSignedIn: credential != nil,
                                     accountLabel: credential?.accountLabel,
                                     isDefault: isDefault))
        }
        return out.sorted { ($0.isDefault ? 0 : 1, $0.path) < ($1.isDefault ? 0 : 1, $1.path) }
    }

    public static func scanSubscriptions() -> [SubscriptionFinding] {
        let pairs: [(CLICredentialSource, ProviderKind)] = [
            (.claudeCode, .anthropicSubscription),
            (.codexCLI, .chatgptSubscription),
            (.geminiCLI, .geminiSubscription),
            (.qwenCLI, .qwenSubscription),
        ]
        return pairs.map { source, kind in
            do {
                let cred = try CLICredentialReader.read(source)
                return SubscriptionFinding(source: source, kind: kind, available: true,
                                           detail: "Signed in · token \(cred.expiresInDescription)")
            } catch let e as DerbyError {
                return SubscriptionFinding(source: source, kind: kind, available: false, detail: e.message)
            } catch {
                return SubscriptionFinding(source: source, kind: kind, available: false,
                                           detail: "Not signed in. Run `\(source.loginCommand)`.")
            }
        }
    }
}
