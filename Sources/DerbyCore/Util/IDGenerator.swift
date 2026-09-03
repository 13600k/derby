import Foundation

/// Monotonic, sortable, human-greppable identifiers (ULID-ish: time prefix +
/// random suffix in Crockford base32).
public enum IDGenerator {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func ulid(now: Date = Date()) -> String {
        var out = ""
        var ms = UInt64(now.timeIntervalSince1970 * 1000)
        var timeChars = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            timeChars[i] = alphabet[Int(ms % 32)]
            ms /= 32
        }
        out.append(contentsOf: timeChars)
        for _ in 0..<16 { out.append(alphabet[Int.random(in: 0..<32)]) }
        return out
    }

    public static func requestID() -> String { "req_" + ulid() }
    public static func attemptID(_ n: Int) -> String { "attempt_\(n)" }
    public static func short() -> String { String(ulid().suffix(10)) }
}

public enum Clock {
    /// Monotonic seconds, safe for measuring durations across wall-clock changes.
    public static var monotonic: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

extension Double {
    public var msString: String {
        if self < 1 { return String(format: "%.0f ms", self * 1000) }
        return String(format: "%.2f s", self)
    }
    public var msRounded: Int { Int((self * 1000).rounded()) }
}
