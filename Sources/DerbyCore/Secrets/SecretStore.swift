import Foundation
import Security

public protocol SecretStore: AnyObject, Sendable {
    func set(_ value: String?, for ref: SecretRef) throws
    func get(_ ref: SecretRef) -> String?
    func delete(_ ref: SecretRef) throws
    /// Removes stored secrets whose refs are no longer present in config.
    func prune(keeping refs: [SecretRef])
}

extension SecretStore {
    public func has(_ ref: SecretRef) -> Bool {
        guard let v = get(ref) else { return false }
        return !v.isEmpty
    }
    /// Never log a secret; show only enough to identify it.
    public func fingerprint(_ ref: SecretRef) -> String? {
        guard let v = get(ref), !v.isEmpty else { return nil }
        return SecretRedactor.fingerprint(v)
    }
}

public enum SecretRedactor {
    public static func fingerprint(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(4, value.count)) }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }
    /// Strips credential material from arbitrary text before it reaches a log.
    public static func redact(_ text: String) -> String {
        var out = text
        let patterns = [
            "(?i)(authorization\\s*:\\s*)(bearer\\s+)?[A-Za-z0-9._\\-+/=]{8,}",
            "(?i)(x-api-key\\s*:\\s*)[A-Za-z0-9._\\-+/=]{8,}",
            "(?i)(api[_-]?key\"?\\s*[:=]\\s*\"?)[A-Za-z0-9._\\-+/=]{8,}",
            "sk-[A-Za-z0-9._\\-]{12,}",
            "sk-ant-[A-Za-z0-9._\\-]{12,}",
            "(?i)(refresh_token\"?\\s*[:=]\\s*\"?)[A-Za-z0-9._\\-+/=]{8,}",
            "(?i)(access_token\"?\\s*[:=]\\s*\"?)[A-Za-z0-9._\\-+/=]{8,}",
            "ey[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{6,}",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "$1[REDACTED]")
        }
        return out
    }
    /// Header dictionaries safe to persist alongside a request record.
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        let sensitive: Set<String> = ["authorization", "x-api-key", "api-key", "cookie",
                                      "x-goog-api-key", "chatgpt-account-id", "openai-organization",
                                      "x-amz-security-token", "proxy-authorization"]
        var out: [String: String] = [:]
        for (k, v) in headers {
            out[k] = sensitive.contains(k.lowercased()) ? "[REDACTED]" : v
        }
        return out
    }
}

public enum SecretStoreError: LocalizedError {
    case keychain(OSStatus, String)
    public var errorDescription: String? {
        switch self {
        case .keychain(let status, let op):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(op) failed: \(msg)"
        }
    }
}

/// macOS Keychain-backed secret storage. One generic-password item per ref,
/// all under a single service so they are easy to audit in Keychain Access.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let service = "com.derby.gateway"
    private let service: String
    private let lock = NSLock()
    /// Read-through cache: the hot request path must not hit the Keychain per request.
    private var cache: [String: String] = [:]

    public init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func set(_ value: String?, for ref: SecretRef) throws {
        lock.lock(); defer { lock.unlock() }
        guard let value, !value.isEmpty else {
            cache.removeValue(forKey: ref.account)
            SecItemDelete(baseQuery(ref.account) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var q = baseQuery(ref.account)
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            let s = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
            guard s == errSecSuccess else { throw SecretStoreError.keychain(s, "update") }
        } else {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(q as CFDictionary, nil)
            guard s == errSecSuccess else { throw SecretStoreError.keychain(s, "add") }
        }
        cache[ref.account] = value
    }

    public func get(_ ref: SecretRef) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[ref.account] { return c }
        var q = baseQuery(ref.account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        cache[ref.account] = s
        return s
    }

    public func delete(_ ref: SecretRef) throws {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: ref.account)
        let s = SecItemDelete(baseQuery(ref.account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw SecretStoreError.keychain(s, "delete") }
    }

    public func prune(keeping refs: [SecretRef]) {
        let keep = Set(refs.map(\.account))
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        q[kSecReturnData as String] = false
        var items: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return }
        for it in list {
            guard let acct = it[kSecAttrAccount as String] as? String, !keep.contains(acct) else { continue }
            try? delete(SecretRef(account: acct))
        }
    }

    /// Updates a generic-password item belonging to another application. Used
    /// only to keep a CLI's own credential store in sync after Derby refreshes
    /// a token on its behalf. Returns false when the item is absent or access
    /// is denied.
    @discardableResult
    public static func updateForeignGenericPassword(service: String, account: String? = nil,
                                                    value: String) -> Bool {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }

    /// Reads a generic-password item belonging to another application (used to
    /// import CLI credentials). Returns nil rather than throwing when denied.
    public static func readForeignGenericPassword(service: String, account: String? = nil) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if let account { q[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Non-persistent store used by tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init(_ seed: [String: String] = [:]) { values = seed }
    public func set(_ value: String?, for ref: SecretRef) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { values[ref.account] = value } else { values.removeValue(forKey: ref.account) }
    }
    public func get(_ ref: SecretRef) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[ref.account]
    }
    public func delete(_ ref: SecretRef) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: ref.account)
    }
    public func prune(keeping refs: [SecretRef]) {
        lock.lock(); defer { lock.unlock() }
        let keep = Set(refs.map(\.account))
        values = values.filter { keep.contains($0.key) }
    }
}
