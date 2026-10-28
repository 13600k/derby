import Foundation

/// Reads another tool's Keychain item through `/usr/bin/security`.
///
/// Claude Code writes its login through this binary, so the item's access list
/// trusts it and a read never raises a dialog. Reading the same item from Derby
/// itself asked again after every rebuild: an ad-hoc signature is identified by
/// its hash, so each build is a new app to the Keychain, and "Always Allow"
/// only ever covered the build that was running. One such item had collected
/// thirty Derby entries, one per build. Hermes Agent reads it the same way.
enum SecurityTool {
    static let path = "/usr/bin/security"

    /// A read that has not answered by now is waiting on a dialog nobody
    /// asked for; ending it is better than holding the caller.
    static let timeout: TimeInterval = 5

    static func findArguments(service: String, account: String? = nil) -> [String] {
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        return arguments + ["-w"]
    }

    /// The password `find-generic-password -w` printed.
    ///
    /// The tool ends it with a newline, and prints the data as hex instead
    /// when any byte is not printable ASCII. Hex that decodes to printable
    /// text, or to no text at all, was therefore the password itself.
    static func decodePassword(_ output: Data) -> String? {
        guard var text = String(data: output, encoding: .utf8) else { return nil }
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if let bytes = hexBytes(text), bytes.contains(where: { !(0x20...0x7E).contains($0) }),
           let decoded = String(data: Data(bytes), encoding: .utf8) {
            return decoded
        }
        return text
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let pair = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(pair)
            index += 2
        }
        return bytes
    }

    static func readPassword(service: String, account: String? = nil) -> String? {
        run(findArguments(service: service, account: account)).flatMap(decodePassword)
    }

    /// Runs the tool and returns its stdout, or nil if it failed or overran.
    /// Synchronous, because `CLICredentialReader.read` is.
    static func run(_ arguments: [String], timeout: TimeInterval = SecurityTool.timeout) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DerbyLog.warn("credentials", "Could not run \(path): \(error.localizedDescription)")
            return nil
        }

        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Drained before waiting, so a large item cannot fill the pipe and
        // leave both sides waiting on each other.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }
}
