import Foundation

public struct HTTPRequestHead: Sendable {
    public var method: String
    public var rawTarget: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var version: String

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var wantsKeepAlive: Bool {
        let c = header("connection")?.lowercased()
        if version == "HTTP/1.0" { return c == "keep-alive" }
        return c != "close"
    }

    init(method: String, rawTarget: String, headers: [String: String], version: String) {
        self.method = method
        self.rawTarget = rawTarget
        self.headers = headers
        self.version = version
        if let q = rawTarget.firstIndex(of: "?") {
            self.path = String(rawTarget[rawTarget.startIndex..<q])
            var out: [String: String] = [:]
            let qs = rawTarget[rawTarget.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncodingSafe
                let v = kv.count > 1 ? String(kv[1]).removingPercentEncodingSafe : ""
                out[k] = v
            }
            self.query = out
        } else {
            self.path = rawTarget
            self.query = [:]
        }
    }
}

extension String {
    var removingPercentEncodingSafe: String {
        replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? self
    }
}

public struct HTTPServerRequest: Sendable {
    public var head: HTTPRequestHead
    public var body: Data
    public var remoteDescription: String
    public var receivedAt: Date

    public var bodyJSON: JSONValue? {
        guard !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: body)
    }
    /// Best-effort client identity for per-application usage breakdowns.
    public var clientName: String {
        if let t = head.header("x-derby-client"), !t.isEmpty { return t }
        if let ua = head.header("user-agent"), !ua.isEmpty {
            // "OpenAI/Python 1.2.3" -> "OpenAI/Python"
            return String(ua.split(separator: " ").first ?? "unknown")
        }
        return "unknown"
    }
}

/// Incrementally writes a streaming response body. Throws once the peer is gone,
/// which is how producers learn the client disconnected.
public protocol HTTPStreamWriter: Sendable {
    func write(_ data: Data) async throws
    func finish() async
    var isCancelled: Bool { get }
}

extension HTTPStreamWriter {
    public func writeSSE(event: String? = nil, data: String) async throws {
        var s = ""
        if let event { s += "event: \(event)\n" }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            s += "data: \(line)\n"
        }
        s += "\n"
        try await write(Data(s.utf8))
    }
    public func writeSSEDone() async throws {
        try await write(Data("data: [DONE]\n\n".utf8))
    }
}

public enum HTTPServerResponse: Sendable {
    case data(status: Int, headers: [String: String], body: Data)
    case stream(status: Int, headers: [String: String],
                producer: @Sendable (any HTTPStreamWriter) async -> Void)

    public static func json(_ status: Int, _ value: JSONValue, headers: [String: String] = [:]) -> HTTPServerResponse {
        var h = headers
        h["content-type"] = "application/json"
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return .data(status: status, headers: h, body: data)
    }
    public static func json(_ status: Int, raw: Data, headers: [String: String] = [:]) -> HTTPServerResponse {
        var h = headers
        h["content-type"] = "application/json"
        return .data(status: status, headers: h, body: raw)
    }
    public static func text(_ status: Int, _ body: String, contentType: String = "text/plain; charset=utf-8") -> HTTPServerResponse {
        .data(status: status, headers: ["content-type": contentType], body: Data(body.utf8))
    }
    public static func empty(_ status: Int, headers: [String: String] = [:]) -> HTTPServerResponse {
        .data(status: status, headers: headers, body: Data())
    }
    public static func sse(status: Int = 200, headers: [String: String] = [:],
                           producer: @escaping @Sendable (any HTTPStreamWriter) async -> Void) -> HTTPServerResponse {
        var h = headers
        h["content-type"] = "text/event-stream; charset=utf-8"
        h["cache-control"] = "no-cache, no-transform"
        h["x-accel-buffering"] = "no"
        return .stream(status: status, headers: h, producer: producer)
    }
}

public enum HTTPStatus {
    public static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 499: return "Client Closed Request"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Unknown"
        }
    }
}
