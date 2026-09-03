import Foundation

public struct OutboundRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Idle timeout for the underlying connection.
    public var timeout: Double
    public var allowInsecureTLS: Bool

    public init(url: URL, method: String = "POST", headers: [String: String] = [:],
                body: Data? = nil, timeout: Double = 120, allowInsecureTLS: Bool = false) {
        self.url = url; self.method = method; self.headers = headers
        self.body = body; self.timeout = timeout; self.allowInsecureTLS = allowInsecureTLS
    }

    var urlRequest: URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if r.value(forHTTPHeaderField: "accept") == nil && r.value(forHTTPHeaderField: "Accept") == nil {
            r.setValue("application/json", forHTTPHeaderField: "accept")
        }
        return r
    }

    /// Header set safe to persist in request history.
    public var redactedHeaders: [String: String] { SecretRedactor.redactHeaders(headers) }
}

public struct OutboundResponse: Sendable {
    public var status: Int
    public var headers: [String: String]   // lowercased keys
    public var body: Data
    public var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
    public var bodyJSON: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
}

public struct SSEEvent: Sendable {
    public var event: String?
    public var data: String
    public var id: String?
    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event; self.data = data; self.id = id
    }
    public var isDone: Bool { data == "[DONE]" }
    public var json: JSONValue? { JSONValue.parse(data) }
}

public struct StreamStart: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var events: AsyncThrowingStream<SSEEvent, Error>
    /// Populated instead of `events` when the provider returned an error status.
    public var errorBody: Data?
}

/// A streaming response delivered as raw byte chunks, for providers that do not
/// use SSE framing (Bedrock's binary event stream).
public struct RawStreamStart: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var bytes: AsyncThrowingStream<Data, Error>
    public var errorBody: Data?
}

/// Outbound HTTP. Abstracted so adapters can be tested against a fake transport
/// without any network.
public protocol HTTPTransport: Sendable {
    func send(_ request: OutboundRequest) async throws -> OutboundResponse
    func stream(_ request: OutboundRequest) async throws -> StreamStart
    func streamRaw(_ request: OutboundRequest) async throws -> RawStreamStart
}

extension HTTPTransport {
    /// Default: buffer the whole response and deliver it as one chunk. Correct
    /// for any transport that does not need incremental raw bytes.
    public func streamRaw(_ request: OutboundRequest) async throws -> RawStreamStart {
        let resp = try await send(request)
        let body = resp.body
        return RawStreamStart(status: resp.status, headers: resp.headers,
                              bytes: AsyncThrowingStream { c in
                                  if (200..<300).contains(resp.status) { c.yield(body) }
                                  c.finish()
                              },
                              errorBody: (200..<300).contains(resp.status) ? nil : body)
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    public static let shared = URLSessionTransport()

    private let lock = NSLock()
    private var sessions: [Bool: URLSession] = [:]
    private let insecureDelegate = InsecureTLSDelegate()

    public init() {}

    private func session(insecure: Bool) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[insecure] { return s }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        cfg.httpShouldUsePipelining = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = insecure
            ? URLSession(configuration: cfg, delegate: insecureDelegate, delegateQueue: nil)
            : URLSession(configuration: cfg)
        sessions[insecure] = s
        return s
    }

    public func send(_ request: OutboundRequest) async throws -> OutboundResponse {
        let s = session(insecure: request.allowInsecureTLS)
        do {
            let (data, response) = try await s.data(for: request.urlRequest)
            let http = response as? HTTPURLResponse
            return OutboundResponse(status: http?.statusCode ?? 0,
                                    headers: Self.lowercasedHeaders(http),
                                    body: data)
        } catch {
            throw Self.mapURLError(error, url: request.url)
        }
    }

    public func stream(_ request: OutboundRequest) async throws -> StreamStart {
        var r = request.urlRequest
        if r.value(forHTTPHeaderField: "accept") == nil { r.setValue("text/event-stream", forHTTPHeaderField: "accept") }
        else if r.value(forHTTPHeaderField: "accept") == "application/json" { r.setValue("text/event-stream", forHTTPHeaderField: "accept") }
        let s = session(insecure: request.allowInsecureTLS)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await s.bytes(for: r) }
        catch { throw Self.mapURLError(error, url: request.url) }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = Self.lowercasedHeaders(http)

        guard (200..<300).contains(status) else {
            // Drain the (small) error body so the adapter can classify it.
            var data = Data()
            do { for try await b in bytes { data.append(b); if data.count > 64_000 { break } } } catch {}
            return StreamStart(status: status, headers: headers,
                               events: AsyncThrowingStream { $0.finish() },
                               errorBody: data)
        }

        let events = AsyncThrowingStream<SSEEvent, Error> { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for event in parser.consume(byte) {
                            continuation.yield(event)
                        }
                    }
                    if let last = parser.flush() { continuation.yield(last) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DerbyError.cancelled())
                } catch {
                    continuation.finish(throwing: Self.mapURLError(error, url: request.url))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamStart(status: status, headers: headers, events: events, errorBody: nil)
    }

    public func streamRaw(_ request: OutboundRequest) async throws -> RawStreamStart {
        let s = session(insecure: request.allowInsecureTLS)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await s.bytes(for: request.urlRequest) }
        catch { throw Self.mapURLError(error, url: request.url) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = Self.lowercasedHeaders(http)
        guard (200..<300).contains(status) else {
            var data = Data()
            do { for try await b in bytes { data.append(b); if data.count > 64_000 { break } } } catch {}
            return RawStreamStart(status: status, headers: headers,
                                  bytes: AsyncThrowingStream { $0.finish() }, errorBody: data)
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    // Coalesce bytes into modest chunks so frame parsing is not
                    // called once per byte.
                    var buf = Data()
                    buf.reserveCapacity(8192)
                    for try await b in bytes {
                        try Task.checkCancellation()
                        buf.append(b)
                        if buf.count >= 4096 { continuation.yield(buf); buf.removeAll(keepingCapacity: true) }
                    }
                    if !buf.isEmpty { continuation.yield(buf) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DerbyError.cancelled())
                } catch {
                    continuation.finish(throwing: Self.mapURLError(error, url: request.url))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return RawStreamStart(status: status, headers: headers, bytes: stream, errorBody: nil)
    }

    static func lowercasedHeaders(_ http: HTTPURLResponse?) -> [String: String] {
        guard let http else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String { out[ks.lowercased()] = "\(v)" }
        }
        return out
    }

    /// Turns URLSession failures into Derby's taxonomy before an adapter sees them.
    static func mapURLError(_ error: Error, url: URL) -> DerbyError {
        if error is CancellationError { return .cancelled() }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            return DerbyError(kind: .unknown, message: error.localizedDescription)
        }
        switch ns.code {
        case NSURLErrorTimedOut:
            return DerbyError(kind: .timeout, message: "Request to \(url.host ?? "provider") timed out")
        case NSURLErrorCancelled:
            return .cancelled()
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return DerbyError(kind: .providerDown, message: "Cannot resolve \(url.host ?? "host")")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorResourceUnavailable:
            return DerbyError(kind: .providerDown, message: "Cannot connect to \(url.host ?? "host"): \(ns.localizedDescription)")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            return DerbyError(kind: .providerDown,
                              message: "TLS failure contacting \(url.host ?? "host"). Enable 'Allow self-signed certificates' if this is a private server.")
        default:
            return DerbyError(kind: .transient, message: ns.localizedDescription)
        }
    }
}

/// Accepts self-signed certificates. Only used by sessions created for accounts
/// that explicitly opted in.
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Incremental Server-Sent Events parser. Byte-at-a-time so it never blocks
/// waiting for a line boundary the provider has not sent yet.
public struct SSEParser {
    private var line = [UInt8]()
    private var dataLines: [String] = []
    private var eventName: String?
    private var eventID: String?
    private var sawAnyField = false

    public init() {}

    public mutating func consume(_ byte: UInt8) -> [SSEEvent] {
        if byte == 0x0A {   // \n
            if line.last == 0x0D { line.removeLast() }   // strip \r
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return handle(line: text)
        }
        line.append(byte)
        return []
    }

    public mutating func consume(_ data: Data) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in data { out.append(contentsOf: consume(b)) }
        return out
    }

    private mutating func handle(line text: String) -> [SSEEvent] {
        if text.isEmpty {
            guard sawAnyField else { return [] }
            let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: eventID)
            dataLines.removeAll(); eventName = nil; eventID = nil; sawAnyField = false
            return [event]
        }
        if text.hasPrefix(":") { return [] }   // comment / heartbeat
        let (field, rawValue): (String, String)
        if let colon = text.firstIndex(of: ":") {
            field = String(text[text.startIndex..<colon])
            var v = String(text[text.index(after: colon)...])
            if v.hasPrefix(" ") { v.removeFirst() }
            rawValue = v
        } else {
            field = text
            rawValue = ""
        }
        sawAnyField = true
        switch field {
        case "data": dataLines.append(rawValue)
        case "event": eventName = rawValue
        case "id": eventID = rawValue
        default: break
        }
        return []
    }

    /// Emits a trailing event when a stream ends without a final blank line.
    public mutating func flush() -> SSEEvent? {
        if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll()
            let events = handle(line: text)
            if let e = events.first { return e }
        }
        guard sawAnyField, !dataLines.isEmpty else { return nil }
        let e = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: eventID)
        dataLines.removeAll(); sawAnyField = false
        return e
    }
}
