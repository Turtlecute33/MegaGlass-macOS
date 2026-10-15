import Foundation

/// A callback may finish before installation, after cancellation, or more than once.
/// Keep the first result and resume outside the lock so completion can be reentrant.
nonisolated final class AsyncResultGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var installed = false

    var isFinished: Bool { lock.withLock { result != nil } }

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let completed = lock.withLock { () -> Result<Value, any Error>? in
            precondition(!installed, "A callback gate can only be awaited once")
            installed = true
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<Value, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }

    func cancel() { finish(.failure(CancellationError())) }
}

/// Only use with cancellation-responsive work (including the SDK request adapter).
/// Canceling the Swift waiter does not undo a request already sent to MEGA.
nonisolated enum RequestDeadline {
    struct Timeout: LocalizedError, Sendable {
        var errorDescription: String? { "The engine did not respond in time. Try again or quit MegaGlass." }
    }

    static func run<Value: Sendable>(for duration: Duration,
                                    _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw Timeout()
            }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
