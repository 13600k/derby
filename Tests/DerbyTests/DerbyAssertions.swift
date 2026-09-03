import Foundation
@testable import DerbyCore

/// Asserts that `body` fails with a specific Derby failure kind.
@discardableResult
func expectFailure(_ kind: FailureKind, _ body: () async throws -> Void,
                   file: String = #fileID, line: Int = #line) async throws -> DerbyError {
    let error = try await expectThrows(body, file: file, line: line)
    guard let derby = error as? DerbyError else {
        throw TestFailure(message: "expected a DerbyError, got \(type(of: error)): \(error)", file: file, line: line)
    }
    if derby.kind != kind {
        throw TestFailure(message: "expected \(kind.rawValue), got \(derby.kind.rawValue) — \(derby.message)",
                          file: file, line: line)
    }
    return derby
}
