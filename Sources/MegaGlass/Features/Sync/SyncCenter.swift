import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

/// Two-way syncs and backups, run by the engine's sync subsystem.
@Observable
final class SyncCenter {
    private(set) var syncs: [MGSyncInfo] = []
    private(set) var stats: [UInt64: MGSyncStats] = [:]
    private(set) var isSyncing = false
    private(set) var isStalled = false
    private(set) var stalls: [MGSyncStall] = []

    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private let controller: MGSyncController
    @ObservationIgnored private let relay = SyncRelay()

    init(engine: MegaEngine) {
        controller = MGSyncController(sdk: engine.sdk)
        relay.center = self
        controller.delegate = relay
    }

    func shutdown() {
        stopped = true
        revision += 1
        controller.invalidate()
        relay.center = nil
    }

    func reload() {
        guard !stopped else { return }
        syncs = controller.syncs
        let ids = Set(syncs.map(\.backupId))
        stats = stats.filter { ids.contains($0.key) }
        refreshGlobalState()
    }

    fileprivate func refreshGlobalState() {
        guard !stopped else { return }
        revision += 1
        let revision = revision
        isSyncing = controller.isSyncing
        let stalled = controller.isStalled
        isStalled = stalled
        if stalled {
            controller.fetchStalls { [weak self] stalls in
                // The bridge calls back on the main queue.
                MainActor.assumeIsolated {
                    guard let self, !self.stopped, self.revision == revision, self.isStalled else { return }
                    self.stalls = stalls
                }
            }
        } else {
            stalls = []
        }
    }

    fileprivate func update(_ value: MGSyncStats) {
        stats[value.backupId] = value
    }

    func add(type: MGSyncType, localFolder: URL, remoteFolder: UInt64?, name: String?) async throws {
        let controller = self.controller
        try await Self.perform { done in
            controller.addSync(of: type, localPath: localFolder.path, name: name,
                               remoteHandle: remoteFolder ?? invalidHandle, completion: done)
        }
        reload()
    }

    func remove(_ sync: MGSyncInfo) async throws {
        let controller = self.controller
        try await Self.perform { controller.removeSync(sync.backupId, completion: $0) }
        stats[sync.backupId] = nil
        reload()
    }

    func setRunning(_ sync: MGSyncInfo, _ running: Bool) async throws {
        let controller = self.controller
        try await Self.perform { controller.setSync(sync.backupId, running: running, completion: $0) }
        reload()
    }

    func rescan(_ sync: MGSyncInfo) {
        controller.rescanSync(sync.backupId)
    }

    private static func perform(_ start: (@escaping @Sendable (Int, String?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            start { code, message in
                if code == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MegaFailure(code: code, message: message ?? MegaFailure.describe(code: code, fallback: "")))
                }
            }
        }
    }

    static func describe(_ sync: MGSyncInfo, stats: MGSyncStats?) -> String {
        if sync.error != 0 { return sync.errorDescription }
        switch sync.runState {
        case .pending, .loading: return "Starting"
        case .suspended: return "Paused"
        case .disabled: return "Disabled"
        default: break
        }
        guard let stats else { return "Up to date" }
        if stats.scanning { return "Scanning" }
        if stats.syncing {
            var parts: [String] = []
            if stats.uploadCount > 0 { parts.append("\(stats.uploadCount) up") }
            if stats.downloadCount > 0 { parts.append("\(stats.downloadCount) down") }
            return parts.isEmpty ? "Syncing" : "Syncing · " + parts.joined(separator: ", ")
        }
        return "Up to date"
    }
}

/// The bridge calls these on the main queue.
private final class SyncRelay: NSObject, MGSyncControllerDelegate {
    weak var center: SyncCenter?

    func syncControllerDidChangeSyncs() { center?.reload() }
    func syncControllerDidUpdate(_ stats: MGSyncStats) { center?.update(stats) }
    func syncControllerDidChangeGlobalState() { center?.refreshGlobalState() }
}
