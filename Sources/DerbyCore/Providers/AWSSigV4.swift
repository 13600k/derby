import Foundation
import CryptoKit

/// Minimal AWS Signature V4 signer — enough for Bedrock Runtime calls.
public enum AWSSigV4 {
    public struct Credentials: Sendable {
        public var accessKeyID: String
        public var secretAccessKey: String
        public var sessionToken: String?
        public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// Returns the headers to add to the request (including `authorization`).
    public static func sign(method: String, url: URL, headers: [String: String], body: Data,
                            region: String, service: String, credentials: Credentials,
                            now: Date = Date()) -> [String: String] {
        let amzDate = amzDateFormatter.string(from: now)
        let dateStamp = dateStampFormatter.string(from: now)
        let payloadHash = sha256Hex(body)

        var signed: [String: String] = [:]
        for (k, v) in headers { signed[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        signed["host"] = url.host ?? ""
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash
        if let token = credentials.sessionToken, !token.isEmpty {
            signed["x-amz-security-token"] = token
        }

        // Canonical request
        let rawPath: String = url.path.isEmpty ? "/" : url.path
        let encodedPath: String = rawPath.addingPercentEncoding(withAllowedCharacters: .awsPathAllowed) ?? rawPath
        let canonicalURI: String = encodedPath

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryPairs: [(String, String)] = []
        for item in comps?.queryItems ?? [] {
            queryPairs.append((item.name.awsEncoded, (item.value ?? "").awsEncoded))
        }
        queryPairs.sort { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        let canonicalQuery: String = queryPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let sortedHeaderNames: [String] = signed.keys.sorted()
        var canonicalHeaders = ""
        for name in sortedHeaderNames {
            canonicalHeaders += name + ":" + (signed[name] ?? "") + "\n"
        }
        let signedHeaderList: String = sortedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            method.uppercased(), canonicalURI, canonicalQuery,
            canonicalHeaders, signedHeaderList, payloadHash,
        ].joined(separator: "\n")

        // String to sign
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")

        // Signing key
        var key = Data("AWS4\(credentials.secretAccessKey)".utf8)
        key = hmac(key, dateStamp)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()

        signed["authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaderList), Signature=\(signature)"
        return signed
    }
}

private extension CharacterSet {
    static let awsPathAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~/")
        return s
    }()
    static let awsQueryAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
}

private extension String {
    var awsEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .awsQueryAllowed) ?? self
    }
}

/// Decoder for the `application/vnd.amazon.eventstream` binary framing used by
/// Bedrock's streaming responses.
public struct AWSEventStreamParser {
    private var buffer = Data()
    public init() {}

    public struct Frame: Sendable {
        public var eventType: String?
        public var messageType: String?
        public var payload: Data
    }

    public mutating func consume(_ data: Data) -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while true {
            guard buffer.count >= 12 else { break }
            let totalLength = Int(be32(buffer, 0))
            let headersLength = Int(be32(buffer, 4))
            guard totalLength >= 16, buffer.count >= totalLength else { break }

            let headerStart = 12
            let headerEnd = headerStart + headersLength
            let payloadEnd = totalLength - 4
            guard headerEnd <= payloadEnd, payloadEnd <= buffer.count else {
                buffer.removeAll()
                break
            }
            let headers = parseHeaders(buffer.subdata(in: headerStart..<headerEnd))
            let payload = buffer.subdata(in: headerEnd..<payloadEnd)
            frames.append(Frame(eventType: headers[":event-type"],
                                messageType: headers[":message-type"],
                                payload: payload))
            buffer.removeSubrange(0..<totalLength)
        }
        return frames
    }

    private func be32(_ d: Data, _ offset: Int) -> UInt32 {
        let i = d.startIndex + offset
        return (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
    }

    private func parseHeaders(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            let nameLen = Int(data[i]); i += 1
            guard i + nameLen <= data.endIndex else { break }
            let name = String(decoding: data[i..<(i + nameLen)], as: UTF8.self)
            i += nameLen
            guard i < data.endIndex else { break }
            let valueType = data[i]; i += 1
            // 7 == string, which is all Bedrock uses for the headers we read.
            if valueType == 7 {
                guard i + 2 <= data.endIndex else { break }
                let len = Int(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
                i += 2
                guard i + len <= data.endIndex else { break }
                out[name] = String(decoding: data[i..<(i + len)], as: UTF8.self)
                i += len
            } else {
                // Skip fixed-size types we do not need.
                let sizes: [UInt8: Int] = [0: 0, 1: 0, 2: 1, 3: 2, 4: 4, 5: 8, 8: 8]
                if let s = sizes[valueType] { i += s } else { break }
            }
        }
        return out
    }
}
