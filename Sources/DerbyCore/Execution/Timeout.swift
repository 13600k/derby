import Foundation

/// Runs `operation` with a deadline. On expiry the operation task is cancelled
/// and a `TIMEOUT` failure is thrown.
public func withDeadline<T: Sendable>(_ seconds: Double,
                                      message: @autoclosure @escaping @Sendable () -> String,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds > 0 else { throw DerbyError.timeout(message()) }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
            throw DerbyError.timeout(message())
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw DerbyError.timeout(message())
        }
        return result
    }
}

/// `withDeadline` for work that may not answer cancellation: it returns at the
/// deadline even while the operation is still stuck, and leaves the operation
/// to finish on its own with its result discarded.
///
/// `withDeadline` cannot do that — a task group waits for every child before
/// it returns, so a child blocked in a synchronous call (a Keychain read
/// waiting on a dialog nobody has answered) holds it past any deadline. Only
/// for work whose late completion is harmless. Both paths resolve the *same*
/// continuation, exactly once, which is the pattern that avoided two hangs
/// elsewhere.
public func withAbandoningDeadline<T: Sendable>(_ seconds: Double,
                                                message: @autoclosure @escaping @Sendable () -> String,
                                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds > 0 else { throw DerbyError.timeout(message()) }
    return try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let work = Task {
            do { once.resume(.success(try await operation())) }
            catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
            if once.resume(.failure(DerbyError.timeout(message()))) { work.cancel() }
        }
    }
}

/// Resumes a continuation at most once, from whichever caller gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

/// Sleeps, translating cancellation into Derby's taxonomy.
public func backoffSleep(_ seconds: Double) async throws {
    guard seconds > 0 else { return }
    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    catch { throw DerbyError.cancelled("Cancelled while backing off") }
}

/// A single-consumer channel that decouples "produce stream events" from
/// "consume with an inactivity timeout".
///
/// Racing `AsyncIterator.next()` against a sleep is unsafe: when the sleep wins,
/// the iterator is left mid-flight and must never be touched again. Buffering
/// through an actor makes the timeout safe — the producer keeps running (or is
/// cancelled) independently of whether the consumer is still waiting.
public actor AsyncEventChannel<Element: Sendable> {
    private var buffer: [Element] = []
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Element?, Error>?

    public init() {}

    public func push(_ value: Element) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: value)
        } else {
            buffer.append(value)
        }
    }

    public func finish(throwing error: Error? = nil) {
        guard !finished else { return }
        finished = true
        failure = error
        if let w = waiter {
            waiter = nil
            if let error { w.resume(throwing: error) } else { w.resume(returning: nil) }
        }
    }

    /// Returns the next element, nil at end of stream, or throws the producer's
    /// error. Throws `TIMEOUT` if nothing arrives within `timeout` seconds.
    ///
    /// The timeout is armed *inside* the actor and resolves by resuming the
    /// waiting continuation. Racing an external `Task.sleep` against a suspended
    /// continuation would leave that continuation permanently unresumed, which
    /// deadlocks the enclosing task group instead of abandoning the attempt.
    public func next(timeout: Double, timeoutMessage: @autoclosure @Sendable () -> String) async throws -> Element? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if finished { return try finishResult() }

        let message = timeoutMessage()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(timeout, 86_400)) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resumeWaiter(throwing: DerbyError.timeout(message))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Element?, Error>) in
                if !buffer.isEmpty {
                    cont.resume(returning: buffer.removeFirst())
                } else if finished {
                    do { cont.resume(returning: try finishResult()) }
                    catch { cont.resume(throwing: error) }
                } else {
                    // Only one consumer is ever active, so this cannot overwrite
                    // a live waiter.
                    waiter = cont
                }
            }
        } onCancel: {
            Task { await self.resumeWaiter(throwing: DerbyError.cancelled()) }
        }
    }

    private func finishResult() throws -> Element? {
        if let failure {
            self.failure = nil
            throw failure
        }
        return nil
    }

    /// Resolves a pending waiter. Safe to call when nobody is waiting.
    private func resumeWaiter(throwing error: Error) {
        guard let w = waiter else { return }
        waiter = nil
        w.resume(throwing: error)
    }
}
