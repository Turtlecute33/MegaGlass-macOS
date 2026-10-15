import Foundation
@preconcurrency import MEGASdk
import MEGABridge

// The binding objects are immutable copies of the engine objects, and MEGASdk is
// thread-safe, so they can cross isolation domains.
extension MEGASdk: @retroactive @unchecked Sendable {}
extension MEGANode: @retroactive @unchecked Sendable {}
extension MEGATransfer: @retroactive @unchecked Sendable {}
extension MEGAError: @retroactive @unchecked Sendable {}
extension MEGAUser: @retroactive @unchecked Sendable {}
extension MEGAContactRequest: @retroactive @unchecked Sendable {}
extension MEGAAccountDetails: @retroactive @unchecked Sendable {}
extension MGSyncInfo: @retroactive @unchecked Sendable {}
extension MGSyncStats: @retroactive @unchecked Sendable {}
extension MGSyncStall: @retroactive @unchecked Sendable {}

/// An engine error with a message for people.
nonisolated struct MegaFailure: LocalizedError, Sendable, Equatable {
    let code: Int
    let message: String

    var errorDescription: String? { message }

    init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: MEGAError) {
        self.init(code: error.type.rawValue, message: Self.describe(code: error.type.rawValue, fallback: error.name))
    }

    var needsTwoFactorCode: Bool { code == MEGAErrorType.apiEMFARequired.rawValue }
    var isBadSession: Bool { code == MEGAErrorType.apiESid.rawValue }

    static func describe(code: Int, fallback: String) -> String {
        switch MEGAErrorType(rawValue: code) {
        case .apiEArgs: "The request is not valid."
        case .apiEAgain, .apiERateLimit, .apiETempUnavail: "The server is busy. Try again in a moment."
        case .apiEExpired: "This link or item has expired."
        case .apiENoent: "The item does not exist or the email or password is incorrect."
        case .apiEAccess: "You do not have access to this item."
        case .apiEExist: "An item with this name already exists."
        case .apiEIncomplete: "The account setup is not complete."
        case .apiEKey: "The decryption key is not correct."
        case .apiESid: "Your session has expired. Log in again."
        case .apiEBlocked: "This item or account is blocked."
        case .apiEOverQuota, .apiEgoingOverquota: "Your storage or transfer quota is full."
        case .apiETooManyConnections, .apiETooMany: "Too many connections or requests. Try again later."
        case .apiEWrite: "The file could not be written."
        case .apiERead: "The file could not be read."
        case .apiEMFARequired: "Enter your two-factor authentication code."
        case .apiEFailed: "The operation failed."
        case .apiEBusinessPastDue: "The business account has expired."
        case .apiEPaywall: "The account is over its storage quota. Free up space or upgrade."
        default: fallback.isEmpty ? "Error \(code)" : fallback
        }
    }
}

/// Bridges one SDK request to async/await.
nonisolated private final class RequestAwaiter: NSObject, MEGARequestDelegate, @unchecked Sendable {
    let gate = AsyncResultGate<MEGARequest>()
    private let accepted: Set<Int>
    private let progress: (@Sendable (Int64, Int64) -> Void)?

    init(accepted: Set<Int>, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.accepted = accepted
        self.progress = progress
    }

    func onRequestUpdate(_ api: MEGASdk, request: MEGARequest) {
        guard !gate.isFinished else { return }
        progress?(request.transferredBytes, request.totalBytes)
    }

    func onRequestFinish(_ api: MEGASdk, request: MEGARequest, error: MEGAError) {
        if error.type == .apiOk || accepted.contains(error.type.rawValue) {
            gate.finish(.success(request))
        } else {
            gate.finish(.failure(MegaFailure(error)))
        }
    }
}

nonisolated extension MEGASdk {
    /// Starts a request with a one-shot delegate and waits for it to finish.
    /// `accepting` lists error codes that count as success.
    func request(accepting: Set<MEGAErrorType> = [],
                 progress: (@Sendable (Int64, Int64) -> Void)? = nil,
                 isolation: isolated (any Actor)? = #isolation,
                 _ start: (any MEGARequestDelegate) -> Void) async throws -> MEGARequest {
        let awaiter = RequestAwaiter(accepted: Set(accepting.map(\.rawValue)), progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation(isolation: isolation) { continuation in
                awaiter.gate.install(continuation)
                guard !awaiter.gate.isFinished else { return }
                // The SDK retains the delegate until finish. Cancellation stops waiting;
                // it does not undo a cloud mutation or free a queued SDK listener.
                start(awaiter)
            }
        } onCancel: {
            awaiter.gate.cancel()
        }
    }

    func nodes(_ list: MEGANodeList?) -> [MEGANode] {
        guard let list else { return [] }
        return (0..<list.size).compactMap { list.node(at: $0) }
    }
}

/// Runs blocking engine calls (they take the engine lock) away from the main thread and
/// away from the Swift cooperative pool.
nonisolated enum EngineQueue {
    private static let queue = DispatchQueue(label: "megaglass.engine-reads", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

nonisolated let invalidHandle: UInt64 = ~0
