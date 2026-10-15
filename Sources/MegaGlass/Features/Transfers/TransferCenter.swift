import AppKit
import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

/// A value copy of one engine transfer callback.
nonisolated struct TransferSnapshot: Sendable {
    /// App data of preview downloads, which the transfer list hides.
    static let previewTag = "megaglass-preview"

    let tag: Int
    let isDownload: Bool
    let name: String
    let path: String?
    let parentPath: String?
    let nodeHandle: UInt64
    let parentHandle: UInt64
    let totalBytes: Int64
    let transferredBytes: Int64
    let speed: Int64
    let state: MEGATransferState
    let stage: MEGATransferStage
    let isFolder: Bool
    let errorMessage: String?
    let finished: Bool

    init(tag: Int, isDownload: Bool = true, name: String = "Item", totalBytes: Int64 = 100,
         transferredBytes: Int64 = 0, state: MEGATransferState = .active,
         errorMessage: String? = nil, finished: Bool = false) {
        self.tag = tag
        self.isDownload = isDownload
        self.name = name
        path = nil
        parentPath = nil
        nodeHandle = invalidHandle
        parentHandle = invalidHandle
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        speed = 0
        self.state = state
        stage = .none
        isFolder = false
        self.errorMessage = errorMessage
        self.finished = finished
    }

    init(_ transfer: MEGATransfer, error: MEGAError? = nil, finished: Bool = false) {
        tag = transfer.tag
        isDownload = transfer.type == .download
        name = transfer.fileName ?? (transfer.path as NSString?)?.lastPathComponent ?? "Item"
        path = transfer.path
        parentPath = transfer.parentPath
        nodeHandle = transfer.nodeHandle
        parentHandle = transfer.parentHandle
        totalBytes = transfer.totalBytes
        transferredBytes = transfer.transferredBytes
        speed = transfer.speed
        state = transfer.state
        stage = transfer.stage
        isFolder = transfer.isFolderTransfer
        if let error, error.type != .apiOk {
            errorMessage = MegaFailure(error).message
        } else {
            errorMessage = nil
        }
        self.finished = finished
    }
}

@Observable
final class TransferItem: Identifiable {
    let id: Int
    let isDownload: Bool
    let isFolder: Bool
    let startedAt = Date()
    var name: String
    var path: String?
    var parentPath: String?
    var nodeHandle: UInt64
    var parentHandle: UInt64
    var totalBytes: Int64 = 0
    var transferredBytes: Int64 = 0
    var speed: Int64 = 0
    var state: MEGATransferState = .queued
    var stage: MEGATransferStage = .none
    var errorMessage: String?
    var finishedAt: Date?

    init(_ snapshot: TransferSnapshot) {
        id = snapshot.tag
        isDownload = snapshot.isDownload
        isFolder = snapshot.isFolder
        name = snapshot.name
        nodeHandle = snapshot.nodeHandle
        parentHandle = snapshot.parentHandle
        update(snapshot)
    }

    func update(_ snapshot: TransferSnapshot) {
        // A concurrent callback queue may deliver an older progress event after finish.
        guard finishedAt == nil else { return }
        if name != snapshot.name { name = snapshot.name }
        path = snapshot.path
        parentPath = snapshot.parentPath
        if snapshot.nodeHandle != invalidHandle { nodeHandle = snapshot.nodeHandle }
        if totalBytes != snapshot.totalBytes { totalBytes = snapshot.totalBytes }
        if transferredBytes != snapshot.transferredBytes { transferredBytes = snapshot.transferredBytes }
        if speed != snapshot.speed { speed = snapshot.speed }
        if state != snapshot.state { state = snapshot.state }
        if stage != snapshot.stage { stage = snapshot.stage }
        errorMessage = snapshot.errorMessage
        if snapshot.finished, finishedAt == nil { finishedAt = Date() }
    }

    var progress: Double {
        totalBytes > 0 ? min(1, max(0, Double(transferredBytes) / Double(totalBytes))) : 0
    }

    var isFinished: Bool {
        finishedAt != nil || state == .complete || state == .cancelled || state == .failed
    }

    var isActive: Bool { !isFinished && state != .paused }

    var statusText: String {
        if let errorMessage, state == .failed { return errorMessage }
        switch state {
        case .complete: return isDownload ? "Downloaded" : "Uploaded"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .paused: return "Paused"
        case .retrying: return errorMessage.map { "Retrying: \($0)" } ?? "Retrying"
        case .queued: return "Waiting"
        case .completing: return "Finishing"
        default:
            switch stage {
            case .scan: return "Scanning"
            case .createTree: return "Creating folders"
            default:
                let remaining = speed > 0 ? Double(totalBytes - transferredBytes) / Double(speed) : .nan
                return "\(Format.speed(speed)) · \(Format.duration(remaining)) left"
            }
        }
    }
}

/// All transfers of the account engine. Engine callbacks arrive on a background queue
/// many times per second; they are merged and applied to the UI at most ~6 times per second.
@Observable
final class TransferCenter {
    private(set) var items: [TransferItem] = []
    private(set) var downloadSpeed: Int64 = 0
    private(set) var uploadSpeed: Int64 = 0
    private(set) var isPaused = false
    /// Stays on for a few seconds after the last transfer, so the pill does not blink
    /// between small files.
    private(set) var showsActivity = false

    @ObservationIgnored private var byTag: [Int: TransferItem] = [:]
    @ObservationIgnored private var feed = TransferFeed()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var pausePending = false
    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var clearedOldPreviews = false
    @ObservationIgnored private let engine: MegaEngine
    /// Serial: the last speed limit that you set is the one the engine keeps.
    nonisolated private static let limitsQueue = DispatchQueue(label: "megaglass.transfer-limits")
    @ObservationIgnored var onFinished: ((TransferItem) -> Void)?

    init(engine: MegaEngine) {
        self.engine = engine
        attachFeed()
    }

    private func attachFeed() {
        let generation = generation
        feed.onDirty = { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped, self.generation == generation else { return }
                self.scheduleFlush()
            }
        }
        engine.sdk.add(feed, queueType: .globalUtility)
    }

    deinit { engine.sdk.remove(feed) }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        generation = UUID()
        hideTask?.cancel()
        engine.sdk.remove(feed)
    }

    func reset() {
        engine.sdk.remove(feed)
        generation = UUID()
        feed = TransferFeed()
        byTag.removeAll()
        items.removeAll()
        hideTask?.cancel()
        hideTask = nil
        showsActivity = false
        isPaused = false
        pausePending = false
        downloadSpeed = 0
        uploadSpeed = 0
        if !stopped { attachFeed() }
    }

    var active: [TransferItem] { items.filter { !$0.isFinished } }
    var finished: [TransferItem] { items.filter(\.isFinished) }
    var activeCount: Int { items.lazy.filter { !$0.isFinished }.count }
    var hasActivity: Bool { activeCount > 0 }

    var overallProgress: Double {
        let running = items.filter { !$0.isFinished }
        let total = running.reduce(0.0) { $0 + Double(max(0, $1.totalBytes)) }
        let done = running.reduce(0.0) { $0 + Double(max(0, $1.transferredBytes)) }
        return total > 0 ? min(1, done / total) : 0
    }

    /// Picks up transfers that the engine resumed from its cache after login.
    func loadExisting() async {
        let generation = generation
        let sdk = engine.sdk
        // Preview downloads of the last run have no window now: the engine must not
        // resume them (quota, and decrypted files that nothing owns). Only once: later
        // loads (an account reload) can have live previews.
        let clearPreviews = !clearedOldPreviews
        clearedOldPreviews = true
        let snapshots = await EngineQueue.run {
            let transfers = (0..<sdk.transfers.size).compactMap { sdk.transfers.transfer(at: $0) }
            if clearPreviews {
                for transfer in transfers where transfer.appData == TransferSnapshot.previewTag {
                    sdk.cancelTransfer(transfer)
                }
            }
            return transfers.filter(TransferFeed.isListed).map { TransferSnapshot($0) }
        }
        guard generation == self.generation, !stopped else { return }
        apply(snapshots)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !stopped, !flushScheduled else { return }
        flushScheduled = true
        let generation = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self else { return }
            self.flushScheduled = false
            guard !self.stopped else { return }
            if generation != self.generation { self.scheduleFlush(); return }
            await self.flush()
        }
    }

    private func flush() async {
        let generation = generation
        apply(feed.drain())
        let sdk = engine.sdk
        // Paused, waiting and retrying transfers do not move: no polling for them (it
        // costs battery). The engine callbacks start the list again.
        let moving = !isPaused && items.contains { $0.state == .active || $0.state == .completing }
        let speeds = moving ? await EngineQueue.run {
            (Int64(sdk.currentDownloadSpeed), Int64(sdk.currentUploadSpeed))
        } : (0, 0)
        guard generation == self.generation, !stopped else { return }
        let running = activeCount > 0
        downloadSpeed = moving ? speeds.0 : 0
        uploadSpeed = moving ? speeds.1 : 0
        if running {
            hideTask?.cancel()
            hideTask = nil
            if !showsActivity { showsActivity = true }
            // Keep the speed readout live while transfers move.
            if moving { scheduleFlush() }
        } else if showsActivity, hideTask == nil {
            hideTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                showsActivity = activeCount > 0
                hideTask = nil
            }
        }
    }

    func apply(_ snapshots: [TransferSnapshot]) {
        guard !snapshots.isEmpty else { return }
        var added: [TransferItem] = []
        for snapshot in snapshots {
            guard !feed.isRetired(snapshot.tag) else { continue }
            if let item = byTag[snapshot.tag] {
                let wasFinished = item.isFinished
                item.update(snapshot)
                if !wasFinished, item.isFinished { onFinished?(item) }
            } else {
                let item = TransferItem(snapshot)
                byTag[snapshot.tag] = item
                added.append(item)
                if item.isFinished { onFinished?(item) }
            }
        }
        if !added.isEmpty { items.append(contentsOf: added) }
        // Keep history and retry snapshots bounded during long-running sync/transfer use.
        let excess = finished.count - 500
        if excess > 0 { Array(finished.prefix(excess)).forEach { remove($0) } }
    }

    // MARK: Actions

    func togglePauseAll() {
        guard !pausePending, !stopped else { return }
        pausePending = true
        let generation = generation
        let pause = !isPaused
        let sdk = engine.sdk
        Task {
            defer { if generation == self.generation { pausePending = false } }
            do {
                _ = try await sdk.request { sdk.pauseTransfers(pause, delegate: $0) }
                guard generation == self.generation, !stopped else { return }
                isPaused = pause
            } catch { if generation == self.generation { onError?(error) } }
        }
    }

    func pause(_ item: TransferItem, _ pause: Bool) {
        engine.sdk.pauseTransfer(byTag: item.id, pause: pause)
    }

    func cancel(_ item: TransferItem) {
        engine.sdk.cancelTransfer(byTag: item.id)
    }

    /// Only the transfers in the list: open previews keep their downloads.
    func cancelAll() {
        for item in items where !item.isFinished { engine.sdk.cancelTransfer(byTag: item.id) }
    }

    func moveToTop(_ item: TransferItem) {
        let sdk = engine.sdk
        let tag = item.id
        // transfer(byTag:) takes the engine lock: not on the main thread.
        Task {
            await EngineQueue.run {
                if let transfer = sdk.transfer(byTag: tag) { sdk.moveTransfer(toFirst: transfer) }
            }
        }
    }

    func retry(_ item: TransferItem) {
        guard let transfer = feed.lastTransfer(item.id) else { return }
        remove(item)
        // retryTransfer uses a transfer delegate, not a request delegate. Its result
        // arrives through the global transfer feed with the new transfer tag.
        engine.sdk.retryTransfer(transfer)
    }

    func remove(_ item: TransferItem) {
        byTag[item.id] = nil
        items.removeAll { $0.id == item.id }
        feed.forget(item.id)
    }

    func clearFinished() {
        for item in items where item.isFinished {
            byTag[item.id] = nil
            feed.forget(item.id)
        }
        items.removeAll(where: \.isFinished)
    }

    func reveal(_ item: TransferItem) {
        guard item.isDownload, let path = item.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    func applyLimits(_ settings: AppSettings) {
        let sdk = engine.sdk
        let downloads = min(32, max(1, settings.downloadConnections))
        let uploads = min(32, max(1, settings.uploadConnections))
        let downloadLimit = Self.bytesPerSecond(settings.downloadLimitKB)
        let uploadLimit = Self.bytesPerSecond(settings.uploadLimitKB)
        // The speed setters take the engine lock: not on the main thread.
        Self.limitsQueue.async {
            sdk.setMaxConnectionsForDirection(.download, connections: downloads)
            sdk.setMaxConnectionsForDirection(.upload, connections: uploads)
            sdk.setMaxDownloadSpeed(downloadLimit)
            sdk.setMaxUploadSpeed(uploadLimit)
        }
    }
    nonisolated static func bytesPerSecond(_ kilobytes: Int) -> Int64 {
        Int64(min(max(0, kilobytes), Int(Int64.max / 1024))) * 1024
    }

}

/// Collects transfer callbacks on the engine's callback queue.
nonisolated final class TransferFeed: NSObject, MEGATransferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: TransferSnapshot] = [:]
    private var order: [Int] = []
    private var retired = Set<Int>()
    private var retirementOrder: [Int] = []
    /// Kept for failed transfers, so they can be retried.
    private var failed: [Int: MEGATransfer] = [:]
    var onDirty: (@Sendable () -> Void)?

    func onTransferStart(_ api: MEGASdk, transfer: MEGATransfer) {
        record(transfer, error: nil, finished: false)
    }

    func onTransferUpdate(_ api: MEGASdk, transfer: MEGATransfer) {
        record(transfer, error: nil, finished: false)
    }

    func onTransferTemporaryError(_ api: MEGASdk, transfer: MEGATransfer, error: MEGAError) {
        record(transfer, error: error, finished: false)
    }

    func onTransferFinish(_ api: MEGASdk, transfer: MEGATransfer, error: MEGAError) {
        if error.type != .apiOk, Self.isListed(transfer) {
            lock.withLock { if !retired.contains(transfer.tag) { failed[transfer.tag] = transfer } }
        }
        record(transfer, error: error, finished: true)
    }

    /// The list shows the transfers that you started. Not listed: the files inside a
    /// folder transfer (the folder reports them), streams, preview downloads, and the
    /// transfers of syncs and backups (the sync engine retries them; a retry from the
    /// list would make a second copy).
    static func isListed(_ transfer: MEGATransfer) -> Bool {
        transfer.folderTransferTag <= 0 && !transfer.isStreamingTransfer
            && transfer.appData != TransferSnapshot.previewTag && !transfer.isSyncTransfer
    }

    private func record(_ transfer: MEGATransfer, error: MEGAError?, finished: Bool) {
        guard Self.isListed(transfer) else { return }
        enqueue(TransferSnapshot(transfer, error: error, finished: finished))
    }

    func enqueue(_ snapshot: TransferSnapshot) {
        let wasEmpty = lock.withLock { () -> Bool in
            if retired.contains(snapshot.tag) { return false }
            if pending[snapshot.tag]?.finished == true { return false }
            let empty = pending.isEmpty
            if pending.updateValue(snapshot, forKey: snapshot.tag) == nil { order.append(snapshot.tag) }
            return empty
        }
        if wasEmpty { onDirty?() }
    }

    func drain() -> [TransferSnapshot] {
        lock.withLock {
            defer { pending.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true) }
            return order.compactMap { pending[$0] }
        }
    }

    func lastTransfer(_ tag: Int) -> MEGATransfer? {
        lock.withLock { failed[tag] }
    }

    func isRetired(_ tag: Int) -> Bool { lock.withLock { retired.contains(tag) } }

    func forget(_ tag: Int) {
        lock.withLock {
            failed[tag] = nil
            pending[tag] = nil
            order.removeAll { $0 == tag }
            if retired.insert(tag).inserted { retirementOrder.append(tag) }
            // Tombstones cover delayed callbacks without growing for the life of the app.
            if retirementOrder.count > 2048 { retired.remove(retirementOrder.removeFirst()) }
        }
    }
}
