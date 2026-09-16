import Foundation
@testable import DerbyCore

/// A minimal test harness.
///
/// Command Line Tools ship neither XCTest nor swift-testing, so Derby's suite is
/// an ordinary executable. Tests register themselves at start-up and `main`
/// runs them, printing a report and exiting non-zero on any failure.
struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: Int
    var description: String { "\(message)  (\(file):\(line))" }
}

struct TestCase {
    let suite: String
    let name: String
    let body: () async throws -> Void
}

final class TestRegistry: @unchecked Sendable {
    static let shared = TestRegistry()
    private(set) var cases: [TestCase] = []
    func add(_ c: TestCase) { cases.append(c) }
}

private var currentSuite = "General"

func suite(_ name: String, _ body: () -> Void) {
    let previous = currentSuite
    currentSuite = name
    body()
    currentSuite = previous
}

func test(_ name: String, _ body: @escaping () async throws -> Void) {
    TestRegistry.shared.add(TestCase(suite: currentSuite, name: name, body: body))
}

// MARK: - Assertions

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
            file: String = #fileID, line: Int = #line) throws {
    if !condition { throw TestFailure(message: message(), file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                               file: String = #fileID, line: Int = #line) throws {
    if actual != expected {
        let extra = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(message: "expected \(expected), got \(actual)\(extra)", file: file, line: line)
    }
}

func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.001,
                 _ message: @autoclosure () -> String = "",
                 file: String = #fileID, line: Int = #line) throws {
    if abs(actual - expected) > tolerance {
        let extra = message().isEmpty ? "" : " — \(message())"
        throw TestFailure(message: "expected ≈\(expected), got \(actual)\(extra)", file: file, line: line)
    }
}

func expectNotNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected non-nil",
                     file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw TestFailure(message: message(), file: file, line: line) }
    return value
}

func expectNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected nil",
                  file: String = #fileID, line: Int = #line) throws {
    if value != nil { throw TestFailure(message: "\(message()) but got \(value!)", file: file, line: line) }
}

func expectContains(_ haystack: String, _ needle: String,
                    file: String = #fileID, line: Int = #line) throws {
    if !haystack.lowercased().contains(needle.lowercased()) {
        throw TestFailure(message: "expected to find \"\(needle)\" in \"\(haystack.prefix(200))\"",
                          file: file, line: line)
    }
}

/// Asserts the body throws, and hands the error back for further checks.
@discardableResult
func expectThrows(_ body: () async throws -> Void,
                  file: String = #fileID, line: Int = #line) async throws -> Error {
    do {
        try await body()
    } catch {
        return error
    }
    throw TestFailure(message: "expected an error to be thrown", file: file, line: line)
}

// MARK: - Runner

@main
struct TestMain {
    /// Redirects every path the suite could write to into a throwaway
    /// directory, before a single test runs.
    ///
    /// `BenchmarkCatalog.refresh` caches to `AppPaths.supportDirectory` on
    /// success, and the pagination suite is the first thing here to drive a
    /// *successful* refresh — so running the tests replaced the real catalog
    /// with a one-row fixture, and the app then reported that Artificial
    /// Analysis had never heard of any configured model. Nothing in a suite
    /// that is required to pass with no network should be able to reach the
    /// user's Application Support directory at all.
    static func isolateOnDiskState() -> URL {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derby-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        AppPaths.supportDirectory = sandbox
        return sandbox
    }

    static func main() async {
        let sandbox = isolateOnDiskState()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        registerAllTests()
        let filter = CommandLine.arguments.dropFirst().first
        let cases = TestRegistry.shared.cases.filter { c in
            guard let filter else { return true }
            return c.suite.localizedCaseInsensitiveContains(filter)
                || c.name.localizedCaseInsensitiveContains(filter)
        }

        var passed = 0
        var failures: [(TestCase, Error)] = []
        var lastSuite = ""
        let started = Date()

        print("Derby test suite — \(cases.count) test\(cases.count == 1 ? "" : "s")\n")
        for c in cases {
            if c.suite != lastSuite {
                lastSuite = c.suite
                print("\u{001B}[1m\(c.suite)\u{001B}[0m")
            }
            do {
                try await c.body()
                passed += 1
                print("  \u{001B}[32m✓\u{001B}[0m \(c.name)")
            } catch {
                failures.append((c, error))
                print("  \u{001B}[31m✗\u{001B}[0m \(c.name)")
                print("      \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("")
        if failures.isEmpty {
            print("\u{001B}[32m\(passed) passed\u{001B}[0m in \(String(format: "%.2fs", elapsed))")
            exit(0)
        } else {
            print("\u{001B}[31m\(failures.count) failed\u{001B}[0m, \(passed) passed in \(String(format: "%.2fs", elapsed))")
            for (c, e) in failures { print("  • \(c.suite) › \(c.name): \(e)") }
            exit(1)
        }
    }
}
