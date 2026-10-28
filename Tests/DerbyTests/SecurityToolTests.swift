import Foundation
@testable import DerbyCore

/// Never runs `/usr/bin/security`: these check what Derby would ask it and how
/// its answer is read, so the suite stays off the real Keychain.
func registerSecurityToolTests() {
    suite("Keychain via /usr/bin/security") {
        test("asks for the password only, scoped to the account when given") {
            try expectEqual(SecurityTool.findArguments(service: "Claude Code-credentials"),
                            ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            try expectEqual(SecurityTool.findArguments(service: "svc", account: "marcu"),
                            ["find-generic-password", "-s", "svc", "-a", "marcu", "-w"])
        }

        test("the trailing newline is not part of the password") {
            let json = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1}}"#
            try expectEqual(SecurityTool.decodePassword(Data((json + "\n").utf8)), json)
        }

        test("data printed as hex decodes to the same text") {
            // `security` prints hex when any byte is not printable ASCII.
            let json = #"{"name":"café"}"#
            let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
            try expectEqual(SecurityTool.decodePassword(Data((hex + "\n").utf8)), json)
        }

        test("a password that merely looks like hex is kept as it is") {
            try expectEqual(SecurityTool.decodePassword(Data("deadbeef\n".utf8)), "deadbeef")
        }

        test("no output is no password") {
            try expectNil(SecurityTool.decodePassword(Data()))
            try expectNil(SecurityTool.decodePassword(Data("\n".utf8)))
        }
    }
}
