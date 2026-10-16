import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

/// What changed in the node tree. Views compare it to decide if they must reload.
nonisolated struct NodeChange: Equatable, Sendable {
    var serial = 0
    var parents: Set<UInt64> = []
    var handles: Set<UInt64> = []
    var isFullReload = false

    func affects(folder handle: UInt64) -> Bool {
        isFullReload || parents.contains(handle) || handles.contains(handle)
    }
}

nonisolated enum EngineEvent: Sendable {
    case nodes(parents: Set<UInt64>, handles: Set<UInt64>, full: Bool)
    case users
    case contactRequests
    case account
    case reloadNeeded
    /// MEGA ended the session (with the reason to show, when there is one).
    case sessionExpired(String?)
    /// The engine could not use its local database and stopped the syncs (an SDK reason code).
    case fatalError(Int)
}

/// One MEGA engine instance: the account, or one open folder link.
@Observable
final class MegaEngine {
    enum Kind: Equatable { case account, folderLink }

    let id: String
    let kind: Kind
    @ObservationIgnored let sdk: MEGASdk
    @ObservationIgnored let thumbnails: ThumbnailStore
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var events = EngineEvents()
    @ObservationIgnored private var eventGeneration = UUID()

    private(set) var nodeChange = NodeChange()
    private(set) var contactsRevision = 0
    private(set) var accountRevision = 0
    @ObservationIgnored var onSessionExpired: ((String?) -> Void)?
    @ObservationIgnored var onReloadNeeded: (() -> Void)?
    @ObservationIgnored var onFatalError: ((Int) -> Void)?

    init(kind: Kind, id: String, basePath: URL, workerThreads: Int, thumbnailDirectory: URL? = nil) {
        self.id = id
        self.kind = kind
        let sdk = MEGASdk.makeSdk(userAgent: "MegaGlass/1.0 (macOS)",
                                  basePath: basePath.path,
                                  workerThreads: UInt(max(1, workerThreads)),
                                  uploadThumbnails: kind == .account)!
        self.sdk = sdk
        thumbnails = ThumbnailStore(sdk: sdk, directory: thumbnailDirectory ?? AppPaths.thumbnails(id))
        attachEvents()
    }

    private func attachEvents() {
        let generation = eventGeneration
        events.deliver = { [weak self] event in
            Task { @MainActor in self?.apply(event, generation: generation) }
        }
        sdk.add(events as any MEGAGlobalDelegate, queueType: .globalUtility)
        sdk.add(events as any MEGARequestDelegate, queueType: .globalUtility)
    }

    /// Discard callbacks already queued for a previous login/account.
    func resetEvents() {
        guard !stopped else { return }
        sdk.remove(events as any MEGAGlobalDelegate)
        sdk.remove(events as any MEGARequestDelegate)
        eventGeneration = UUID()
        events = EngineEvents()
        attachEvents()
    }

    deinit {
        sdk.remove(events as any MEGAGlobalDelegate)
        sdk.remove(events as any MEGARequestDelegate)
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        sdk.remove(events as any MEGAGlobalDelegate)
        sdk.remove(events as any MEGARequestDelegate)
        onReloadNeeded = nil
        onSessionExpired = nil
        onFatalError = nil
    }

    private func apply(_ event: EngineEvent, generation: UUID) {
        guard !stopped, generation == eventGeneration else { return }
        switch event {
        case let .nodes(parents, handles, full):
            nodeChange = NodeChange(serial: nodeChange.serial + 1, parents: parents, handles: handles, isFullReload: full)
        case .users, .contactRequests:
            contactsRevision += 1
        case .account:
            accountRevision += 1
        case .reloadNeeded:
            onReloadNeeded?()
        case let .sessionExpired(reason):
            onSessionExpired?(reason)
        case let .fatalError(reason):
            onFatalError?(reason)
        }
    }

    // MARK: Reads (run on the engine read queue)

    nonisolated func item(for handle: UInt64) async -> NodeItem? {
        await EngineQueue.run { [sdk] in sdk.node(forHandle: handle).map { NodeItem($0) } }
    }

    nonisolated func node(_ handle: UInt64) -> MEGANode? {
        sdk.node(forHandle: handle)
    }
}

/// Receives global engine callbacks on a background queue and sends small summaries.
nonisolated private final class EngineEvents: NSObject, MEGAGlobalDelegate, MEGARequestDelegate, @unchecked Sendable {
    var deliver: (@Sendable (EngineEvent) -> Void)?

    func onRequestFinish(_ api: MEGASdk, request: MEGARequest, error: MEGAError) {
        // When MEGA ends the session (closed on the web, or the account is blocked) with no
        // request waiting, the engine logs out by itself: that logout finishes with no error.
        let loggedOutByEngine = request.type == .MEGARequestTypeLogout
            && [MEGAErrorType.apiESid.rawValue, MEGAErrorType.apiEBlocked.rawValue].contains(request.paramType)
        if error.type == .apiESid || loggedOutByEngine { deliver?(.sessionExpired(nil)) }
    }

    func onEvent(_ api: MEGASdk, event: MEGAEvent) {
        switch event.type {
        case .accountBlocked:
            deliver?(.sessionExpired(event.text))
        case .fatalError:
            deliver?(.fatalError(event.number))
        default:
            break
        }
    }

    func onNodesUpdate(_ api: MEGASdk, nodeList: MEGANodeList?) {
        guard let nodeList else {
            deliver?(.nodes(parents: [], handles: [], full: true))
            return
        }
        var parents = Set<UInt64>()
        var handles = Set<UInt64>()
        for index in 0..<nodeList.size {
            guard let node = nodeList.node(at: index) else { continue }
            parents.insert(node.parentHandle)
            handles.insert(node.handle)
        }
        deliver?(.nodes(parents: parents, handles: handles, full: false))
    }

    func onUsersUpdate(_ api: MEGASdk, userList: MEGAUserList?) { deliver?(.users) }
    func onContactRequestsUpdate(_ api: MEGASdk, contactRequestList: MEGAContactRequestList?) { deliver?(.contactRequests) }
    func onAccountUpdate(_ api: MEGASdk) { deliver?(.account) }
    func onReloadNeeded(_ api: MEGASdk) { deliver?(.reloadNeeded) }
}
