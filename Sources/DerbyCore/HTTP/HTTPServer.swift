import Foundation
import Network

public enum HTTPServerError: LocalizedError {
    case portInUse(Int)
    case bindFailed(String)
    case notRunning
    public var errorDescription: String? {
        switch self {
        case .portInUse(let p): return "Port \(p) is already in use. Choose a different port in Settings."
        case .bindFailed(let m): return "The gateway could not start listening: \(m)"
        case .notRunning: return "The gateway is not running."
        }
    }
}

public typealias HTTPHandler = @Sendable (HTTPServerRequest) async -> HTTPServerResponse

/// A small, dependency-free HTTP/1.1 server on Network.framework.
///
/// Supports keep-alive, `Content-Length` request bodies, and chunked streaming
/// responses (which is how SSE is delivered). Each connection is serviced by its
/// own task, so slow streaming clients never block other requests.
public actor HTTPServer {
    public private(set) var isRunning = false
    public private(set) var boundPort: Int = 0

    private var listener: NWListener?
    private var handler: HTTPHandler?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let queue = DispatchQueue(label: "com.derby.http.listener")
    private var maxConcurrent: Int = 64
    private var maxBodyBytes = 64 * 1024 * 1024

    public init() {}

    public func start(host: String, port: Int, maxConcurrentRequests: Int = 64,
                      handler: @escaping HTTPHandler) async throws {
        if isRunning { await stop() }
        self.handler = handler
        self.maxConcurrent = max(1, maxConcurrentRequests)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw HTTPServerError.bindFailed("invalid port \(port)")
        }
        // Bind to one specific local address. `acceptLocalOnly` is not enough:
        // it restricts peers to the local link but still binds every interface,
        // so the listener would show up as *:port. Pinning the local endpoint is
        // what actually keeps a loopback gateway off the network.
        let isLoopback = GatewaySettings.isLoopback(host)
        if isLoopback {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        } else if host != "0.0.0.0" && !host.isEmpty {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        // When a local endpoint is pinned, the port comes from that endpoint —
        // passing `on:` as well makes the initializer throw.
        let l: NWListener
        do {
            if params.requiredLocalEndpoint != nil {
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: nwPort)
            }
        } catch {
            throw HTTPServerError.bindFailed("\(error)")
        }

        self.listener = l
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            Task { await self.accept(conn) }
        }

        // A watchdog guarantees `start` always returns: a listener that never
        // reaches `.ready` would otherwise hang the whole app at launch.
        let startQueue = queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumed = Resumed()
                // Resolve the same continuation from a timer rather than racing a
                // task group: cancelling a suspended continuation would never
                // resume it, and the caller would hang instead of failing.
                startQueue.asyncAfter(deadline: .now() + 10) {
                    if resumed.take() {
                        cont.resume(throwing: HTTPServerError.bindFailed(
                            "the listener did not become ready within 10s (port \(port), address \(host))"))
                    }
                }
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.take() { cont.resume() }
                    case .waiting(let err):
                        // `.waiting` is normally transient, but an address clash
                        // never resolves on its own, so surface it now.
                        if err == .posix(.EADDRINUSE) || err == .posix(.EACCES) {
                            if resumed.take() {
                                cont.resume(throwing: err == .posix(.EADDRINUSE)
                                    ? HTTPServerError.portInUse(port)
                                    : HTTPServerError.bindFailed("permission denied binding \(host):\(port)"))
                            }
                        }
                    case .failed(let err):
                        if resumed.take() {
                            let e: Error = (err == .posix(.EADDRINUSE))
                                ? HTTPServerError.portInUse(port)
                                : HTTPServerError.bindFailed(String(describing: err))
                            cont.resume(throwing: e)
                        }
                    case .cancelled:
                        if resumed.take() { cont.resume(throwing: HTTPServerError.bindFailed("cancelled")) }
                    default: break
                    }
                }
                l.start(queue: startQueue)
        }

        boundPort = Int(l.port?.rawValue ?? UInt16(port))
        isRunning = true
    }

    public func stop() async {
        isRunning = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let conns = connections.values
        connections.removeAll()
        for c in conns { await c.close() }
    }

    public var activeConnectionCount: Int { connections.count }

    private func accept(_ nw: NWConnection) {
        guard isRunning || listener != nil, let handler else { nw.cancel(); return }
        if connections.count >= maxConcurrent * 4 {
            // Shed load rather than accumulating unbounded connections.
            nw.cancel()
            return
        }
        let conn = Connection(nw: nw, handler: handler, maxBodyBytes: maxBodyBytes)
        connections[ObjectIdentifier(conn)] = conn
        Task {
            await conn.run()
            await self.remove(conn)
        }
    }

    private func remove(_ conn: Connection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }
}

/// One-shot guard so a continuation is never resumed twice.
private final class Resumed: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - Connection

private actor Connection {
    private let nw: NWConnection
    private let handler: HTTPHandler
    private let maxBodyBytes: Int
    private var buffer = Data()
    private var closed = false
    private let queue = DispatchQueue(label: "com.derby.http.conn")

    init(nw: NWConnection, handler: @escaping HTTPHandler, maxBodyBytes: Int) {
        self.nw = nw
        self.handler = handler
        self.maxBodyBytes = maxBodyBytes
    }

    func close() {
        guard !closed else { return }
        closed = true
        nw.cancel()
    }

    var isClosed: Bool { closed }

    func run() async {
        await waitReady()
        guard !closed else { return }
        let remote = Self.describe(nw.currentPath?.remoteEndpoint ?? nw.endpoint)

        while !closed {
            guard let head = await readHead() else { break }

            // Reject encodings we do not implement rather than mis-parsing them.
            if let te = head.header("transfer-encoding")?.lowercased(), te.contains("chunked") {
                await writeSimple(status: 501, body: "Chunked request bodies are not supported", close: true)
                break
            }
            let length = Int(head.header("content-length") ?? "0") ?? 0
            if length > maxBodyBytes {
                await writeSimple(status: 413, body: "Request body too large", close: true)
                break
            }
            guard let body = await readBody(length: length) else { break }

            let req = HTTPServerRequest(head: head, body: body, remoteDescription: remote, receivedAt: Date())
            let response = await handler(req)
            let keepAlive = head.wantsKeepAlive && !closed

            switch response {
            case .data(let status, let headers, let payload):
                await writeFull(status: status, headers: headers, body: payload, keepAlive: keepAlive)
            case .stream(let status, let headers, let producer):
                await writeStream(status: status, headers: headers, keepAlive: keepAlive, producer: producer)
            }

            if !keepAlive { break }
        }
        close()
    }

    private static func describe(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "unknown" }
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    private func waitReady() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = Resumed()
            nw.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if resumed.take() { cont.resume() }
                default: break
                }
            }
            nw.start(queue: queue)
        }
        if case .ready = nw.state {} else { closed = true }
    }

    /// Reads until the end of the header block, returning nil on EOF/error.
    private func readHead() async -> HTTPRequestHead? {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = buffer.firstRange(of: terminator) {
                let headData = buffer[buffer.startIndex..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return Self.parseHead(Data(headData))
            }
            if buffer.count > 1_048_576 { return nil }   // header bomb
            guard let chunk = await receive(), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }

    private func readBody(length: Int) async -> Data? {
        guard length > 0 else { return Data() }
        while buffer.count < length {
            guard let chunk = await receive(), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        let body = buffer.prefix(length)
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: length))
        return Data(body)
    }

    private static func parseHead(_ data: Data) -> HTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let version = requestLine.count > 2 ? String(requestLine[2]) : "HTTP/1.1"
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] { headers[name] = existing + ", " + value }
            else { headers[name] = value }
        }
        return HTTPRequestHead(method: method, rawTarget: target, headers: headers, version: version)
    }

    private func receive() async -> Data? {
        guard !closed else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let resumed = Resumed()
            nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                guard resumed.take() else { return }
                if error != nil { cont.resume(returning: nil); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                cont.resume(returning: isComplete ? nil : Data())
            }
        }
    }

    @discardableResult
    private func send(_ data: Data) async -> Bool {
        guard !closed, !data.isEmpty else { return !closed }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = Resumed()
            nw.send(content: data, completion: .contentProcessed { error in
                guard resumed.take() else { return }
                cont.resume(returning: error == nil)
            })
        }
    }

    private func headerBlock(status: Int, headers: [String: String], keepAlive: Bool) -> Data {
        var out = "HTTP/1.1 \(status) \(HTTPStatus.reason(status))\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            out += "\(k): \(v)\r\n"
        }
        out += "connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        out += "date: \(HTTPDateFormatter.string(from: Date()))\r\n"
        out += "\r\n"
        return Data(out.utf8)
    }

    private func writeFull(status: Int, headers: [String: String], body: Data, keepAlive: Bool) async {
        var h = headers
        h["content-length"] = "\(body.count)"
        var out = headerBlock(status: status, headers: h, keepAlive: keepAlive)
        out.append(body)
        if await send(out) == false { closed = true }
    }

    private func writeSimple(status: Int, body: String, close shouldClose: Bool) async {
        await writeFull(status: status,
                        headers: ["content-type": "text/plain; charset=utf-8"],
                        body: Data(body.utf8), keepAlive: !shouldClose)
        if shouldClose { closed = true }
    }

    private func writeStream(status: Int, headers: [String: String], keepAlive: Bool,
                             producer: @Sendable (any HTTPStreamWriter) async -> Void) async {
        var h = headers
        h["transfer-encoding"] = "chunked"
        guard await send(headerBlock(status: status, headers: h, keepAlive: keepAlive)) else {
            closed = true
            return
        }
        let writer = ChunkWriter(connection: self)
        await producer(writer)
        await writer.finish()
    }

    /// Writes one HTTP chunk. Returns false once the peer is gone.
    fileprivate func writeChunk(_ payload: Data) async -> Bool {
        guard !closed else { return false }
        var out = Data(String(format: "%llx\r\n", UInt64(payload.count)).utf8)
        out.append(payload)
        out.append(Data("\r\n".utf8))
        let ok = await send(out)
        if !ok { closed = true }
        return ok
    }

    fileprivate func writeTerminalChunk() async {
        guard !closed else { return }
        _ = await send(Data("0\r\n\r\n".utf8))
    }
}

private final class ChunkWriter: HTTPStreamWriter, @unchecked Sendable {
    private let connection: Connection
    private let cancelledFlag = AtomicFlag()
    private let finished = AtomicFlag()

    init(connection: Connection) { self.connection = connection }

    var isCancelled: Bool { cancelledFlag.value }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if cancelledFlag.value { throw DerbyError.cancelled("Client disconnected") }
        let ok = await connection.writeChunk(data)
        if !ok {
            cancelledFlag.set()
            throw DerbyError.cancelled("Client disconnected")
        }
    }

    func finish() async {
        guard finished.trySet() else { return }
        if !cancelledFlag.value { await connection.writeTerminalChunk() }
    }
}

final class AtomicFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    /// Sets the flag, returning false if it was already set.
    func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

enum HTTPDateFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
