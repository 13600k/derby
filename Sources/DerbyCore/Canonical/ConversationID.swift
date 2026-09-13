import Foundation
import CryptoKit

extension CanonicalRequest {
    /// Which conversation this request belongs to — the same on every turn of it.
    ///
    /// A client that names its conversation (`prompt_cache_key`) is taken at its
    /// word. Otherwise a recorded answer in the history says which conversation
    /// it was written in, which survives a client rewriting how the history
    /// begins, as context compression does. A conversation with no recorded
    /// answer yet is named by its opening: the leading instructions and the
    /// user's first message.
    public var conversationKey: String {
        if let key = promptCacheKey, !key.isEmpty { return Self.digest("key\u{1F}" + key) }
        if let continued = continuesConversation, !continued.isEmpty { return continued }
        let instructions = messages.prefix(while: { $0.role == .system || $0.role == .developer })
        return Self.digest("opening\u{1F}" + instructions.map(\.joinedText).joined(separator: "\u{1E}")
                           + "\u{1F}" + (messages.first { $0.role == .user }?.joinedText ?? ""))
    }

    /// Names the conversation on one account: the same name on every turn, and a
    /// different one for the same conversation on another account. Shaped like a
    /// UUID, the form a session header takes.
    public func conversationID(scope: String) -> String {
        var bytes = Array(SHA256.hash(data: Data((scope + "\u{1F}" + conversationKey).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // RFC 9562 version 8: application-defined
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 9562 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                hex.dropFirst(16).prefix(4), hex.dropFirst(20)].joined(separator: "-")
    }

    private static func digest(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
