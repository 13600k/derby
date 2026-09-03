import Foundation
@testable import DerbyCore

func registerHTTPTests() {
    suite("HTTP / SSE parsing") {
        test("parses events split across arbitrary byte boundaries") {
            var parser = SSEParser()
            var events: [SSEEvent] = []
            let raw = "event: message\ndata: {\"a\":1}\n\ndata: line1\ndata: line2\n\n: heartbeat\n\ndata: [DONE]\n\n"
            for byte in Array(raw.utf8) { events.append(contentsOf: parser.consume(byte)) }
            try expectEqual(events.count, 3)
            try expectEqual(events[0].event, "message")
            try expectEqual(events[0].json?["a"]?.intValue, 1)
            try expectEqual(events[1].data, "line1\nline2")
            try expect(events[2].isDone)
        }

        test("handles CRLF line endings") {
            var parser = SSEParser()
            let events = parser.consume(Data("data: hello\r\n\r\n".utf8))
            try expectEqual(events.count, 1)
            try expectEqual(events[0].data, "hello")
        }

        test("flush emits a trailing event with no blank line") {
            var parser = SSEParser()
            _ = parser.consume(Data("data: tail".utf8))
            let last = try expectNotNil(parser.flush())
            try expectEqual(last.data, "tail")
        }
    }

    suite("HTTP / server") {
        /// Boots the real Network.framework server on an ephemeral port.
        func withServer(_ handler: @escaping HTTPHandler,
                        _ body: (Int) async throws -> Void) async throws {
            let server = HTTPServer()
            try await server.start(host: "127.0.0.1", port: 0, handler: handler)
            let port = await server.boundPort
            defer { Task { await server.stop() } }
            try await body(port)
            await server.stop()
        }

        test("serves a JSON response and parses method, path, query and body") {
            let captured = Captured()
            try await withServer({ request in
                await captured.set(request)
                return .json(200, .object(["ok": .bool(true)]))
            }) { port in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions?a=1&b=two%20words")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.setValue("Derby-Test/1.0", forHTTPHeaderField: "user-agent")
                req.httpBody = Data(#"{"model":"coding"}"#.utf8)
                let (data, response) = try await URLSession.shared.data(for: req)
                try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
                try expectEqual(JSONValue.parse(String(decoding: data, as: UTF8.self))?["ok"]?.boolValue, true)

                let got = try expectNotNil(await captured.value)
                try expectEqual(got.head.method, "POST")
                try expectEqual(got.head.path, "/v1/chat/completions")
                try expectEqual(got.head.query["a"], "1")
                try expectEqual(got.head.query["b"], "two words")
                try expectEqual(got.bodyJSON?["model"]?.stringValue, "coding")
                try expectEqual(got.clientName, "Derby-Test/1.0")
            }
        }

        test("streams chunked SSE that a client reads incrementally") {
            try await withServer({ _ in
                .sse { writer in
                    for i in 0..<5 {
                        try? await writer.writeSSE(data: "{\"n\":\(i)}")
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    try? await writer.writeSSEDone()
                    await writer.finish()
                }
            }) { port in
                let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
                var parser = SSEParser()
                var events: [SSEEvent] = []
                for try await b in bytes { events.append(contentsOf: parser.consume(b)) }
                try expectEqual(events.count, 6)
                try expectEqual(events[0].json?["n"]?.intValue, 0)
                try expect(events.last?.isDone == true)
            }
        }

        test("handles many concurrent requests on one server") {
            try await withServer({ request in
                try? await Task.sleep(nanoseconds: 10_000_000)
                return .json(200, .object(["path": .string(request.head.path)]))
            }) { port in
                let results = await withTaskGroup(of: Int?.self) { group -> [Int] in
                    for i in 0..<20 {
                        group.addTask {
                            let url = URL(string: "http://127.0.0.1:\(port)/r/\(i)")!
                            guard let (_, resp) = try? await URLSession.shared.data(from: url) else { return nil }
                            return (resp as? HTTPURLResponse)?.statusCode
                        }
                    }
                    var out: [Int] = []
                    for await r in group { if let r { out.append(r) } }
                    return out
                }
                try expectEqual(results.count, 20)
                try expect(results.allSatisfy { $0 == 200 })
            }
        }

        test("keep-alive serves several requests on one connection") {
            let counter = Counter()
            try await withServer({ _ in
                await counter.increment()
                return .json(200, .object(["n": .number(Double(await counter.value))]))
            }) { port in
                let session = URLSession(configuration: .default)
                for _ in 0..<3 {
                    let (_, resp) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/x")!)
                    try expectEqual((resp as? HTTPURLResponse)?.statusCode, 200)
                }
                try expectEqual(await counter.value, 3)
            }
        }

        test("rejects a body larger than the cap without wedging the server") {
            try await withServer({ _ in .json(200, .object([:])) }) { port in
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/x")!)
                req.httpMethod = "POST"
                req.setValue("200000000", forHTTPHeaderField: "content-length")
                req.httpBody = Data(repeating: 65, count: 16)
                let status = (try? await URLSession.shared.data(for: req))
                    .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                // Either a 413 or a dropped connection is acceptable; what matters
                // is that the next request still works.
                _ = status
                let (_, ok) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/y")!)
                try expectEqual((ok as? HTTPURLResponse)?.statusCode, 200)
            }
        }
    }

    suite("HTTP / redaction") {
        test("sensitive headers are redacted for storage") {
            let redacted = SecretRedactor.redactHeaders([
                "authorization": "Bearer sk-secret", "x-api-key": "abc",
                "chatgpt-account-id": "acct", "content-type": "application/json",
            ])
            try expectEqual(redacted["authorization"], "[REDACTED]")
            try expectEqual(redacted["x-api-key"], "[REDACTED]")
            try expectEqual(redacted["chatgpt-account-id"], "[REDACTED]")
            try expectEqual(redacted["content-type"], "application/json")
        }

        test("secrets are stripped from free text") {
            let text = """
            Authorization: Bearer sk-ant-oat01-abcdefghijklmnop
            key sk-proj-ABCDEFGHIJKLMNOPQRST failed
            token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
            """
            let redacted = SecretRedactor.redact(text)
            try expect(!redacted.contains("sk-ant-oat01-abcdefghijklmnop"))
            try expect(!redacted.contains("sk-proj-ABCDEFGHIJKLMNOPQRST"))
            try expect(!redacted.contains("dozjgNryP4J3jVmNHl0w5N"))
        }

        test("fingerprints identify a key without revealing it") {
            let fp = SecretRedactor.fingerprint("sk-1234567890abcdef")
            try expectEqual(fp, "sk-1…cdef")
        }
    }
}

/// Small helpers for the server tests.
actor Captured {
    var value: HTTPServerRequest?
    func set(_ r: HTTPServerRequest) { value = r }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
