import Foundation

/// Runs a local executable and streams its stdout line by line.
///
/// Derby needs this because some providers are reached through a command-line
/// tool rather than an HTTP endpoint — notably Claude Code, whose CLI is a
/// first-party client and therefore draws on a subscription's plan limits, where
/// calling the API directly with the same token is billed as third-party extra
/// usage.
public enum ProcessRunner {

    public struct Failure: Error, CustomStringConvertible {
        public var status: Int32
        public var stderr: String
        public var description: String {
            stderr.isEmpty ? "process exited with status \(status)" : stderr
        }
    }

    /// Locations to look for a CLI when `PATH` is not helpful.
    ///
    /// A GUI app launched from Finder inherits a minimal `PATH` that excludes
    /// `~/.local/bin` and Homebrew, so resolving by name alone fails in exactly
    /// the situation that matters.
    public static func locate(_ name: String, extraCandidates: [String] = []) -> URL? {
        let home = CLICredentialReader.home()
        var candidates = extraCandidates
        candidates += [
            home.appendingPathComponent(".local/bin/\(name)").path,
            home.appendingPathComponent(".claude/local/\(name)").path,
            home.appendingPathComponent(".bun/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        // Anything already on this process's PATH.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    /// A process environment that can actually find a user-installed CLI.
    ///
    /// The same reason `locate` exists: a GUI app launched from Finder inherits
    /// only a minimal `PATH`, and these tools are Node shims that then fail to
    /// find their own interpreter — working perfectly from a terminal and not at
    /// all from the app. `preferred`, when given, goes first, so a configured
    /// override wins over whatever else is on `PATH`.
    public static func toolEnvironment(preferring preferred: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = CLICredentialReader.home().path
        var searchPaths = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        if let preferred { searchPaths.insert(preferred.deletingLastPathComponent().path, at: 0) }
        for extra in ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.nvm/current/bin",
                      "\(home)/.volta/bin", "\(home)/n/bin", "/opt/homebrew/bin",
                      "/usr/local/bin", "/usr/bin", "/bin"] where !searchPaths.contains(extra) {
            searchPaths.append(extra)
        }
        env["PATH"] = searchPaths.joined(separator: ":")
        if env["HOME"] == nil { env["HOME"] = home }
        return env
    }

    /// Launches `executable` and yields its stdout as lines.
    ///
    /// The stream terminates when the process exits; a non-zero exit throws a
    /// `Failure` carrying stderr, so a caller can report why. Cancelling the
    /// consuming task terminates the process, which is what makes a request
    /// deadline actually stop the work.
    public static func streamLines(executable: URL,
                                   arguments: [String],
                                   environment: [String: String],
                                   currentDirectory: URL? = nil,
                                   standardInput: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            let out = Pipe()
            let err = Pipe()
            let input = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input

            // Guarded by `stateLock`; touched from the reader queue and from
            // the termination handler.
            let stateLock = NSLock()
            var pending = Data()
            var stderrData = Data()
            var finished = false
            var sawOutput = false

            func finish(_ error: Error?) {
                stateLock.lock()
                let alreadyDone = finished
                finished = true
                stateLock.unlock()
                guard !alreadyDone else { return }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }

            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stateLock.lock()
                pending.append(chunk)
                var lines: [String] = []
                while let index = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<index]
                    pending.removeSubrange(pending.startIndex...index)
                    if let line = String(data: Data(lineData), encoding: .utf8) { lines.append(line) }
                }
                let isFirst = sawOutput == false
                if isFirst { sawOutput = true }
                stateLock.unlock()
                if isFirst { DerbyLog.info("process", "first stdout from pid=\(process.processIdentifier)") }
                for line in lines where !line.isEmpty { continuation.yield(line) }
            }

            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stateLock.lock()
                // Bound it: a runaway process must not grow this without limit.
                if stderrData.count < 64_000 { stderrData.append(chunk) }
                stateLock.unlock()
            }

            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil

                // Drain whatever arrived between the last handler call and exit.
                let remaining = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                stateLock.lock()
                pending.append(remaining)
                let tail = pending
                pending = Data()
                if stderrData.count < 64_000,
                   let extra = try? err.fileHandleForReading.readToEnd() {
                    stderrData.append(extra)
                }
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                stateLock.unlock()

                for line in String(data: tail, encoding: .utf8)?
                    .split(separator: "\n", omittingEmptySubsequences: true) ?? [] {
                    continuation.yield(String(line))
                }

                DerbyLog.info("process", "pid=\(proc.processIdentifier) exited status=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue) stderr=\(String(stderrText.prefix(400)))")
                if proc.terminationReason == .uncaughtSignal {
                    // Cancelled by us; ending cleanly is correct.
                    finish(nil)
                } else if proc.terminationStatus != 0 {
                    finish(Failure(status: proc.terminationStatus, stderr: stderrText))
                } else {
                    finish(nil)
                }
            }

            continuation.onTermination = { _ in
                guard process.isRunning else { return }
                process.terminate()
                // SIGTERM is not always enough for a process mid-request; make
                // sure it cannot outlive the gateway request that started it.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }

            do {
                try process.run()
                DerbyLog.info("process", "launched \(executable.lastPathComponent) pid=\(process.processIdentifier)")
            } catch {
                DerbyLog.warn("process", "could not launch \(executable.path): \(error)")
                finish(error)
                return
            }

            if let standardInput {
                let handle = input.fileHandleForWriting
                handle.write(Data(standardInput.utf8))
                try? handle.close()
            } else {
                try? input.fileHandleForWriting.close()
            }
        }
    }
}
