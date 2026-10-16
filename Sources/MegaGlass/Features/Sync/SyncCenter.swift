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

    /// Syncs and backups that the engine stopped with an error. The engine's
    /// stalled and syncing flags do not include them.
    var stoppedCount: Int { syncs.count(where: { $0.error != 0 }) }

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
        if let problem = Self.rootProblem(localFolder, otherRoots: controller.syncs.map(\.localPath)) {
            throw MegaFailure(code: MEGAErrorType.apiEArgs.rawValue, message: problem)
        }
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
        if sync.error != 0 { return describeError(sync.error, fallback: sync.errorDescription) }
        switch sync.runState {
        case .pending, .loading: return "Starting"
        case .suspended: return "Paused"
        case .disabled: return "Disabled"
        default: break
        }
        guard let stats else { return "Starting" }
        if stats.scanning { return "Scanning" }
        if stats.syncing {
            var parts: [String] = []
            if stats.uploadCount > 0 { parts.append("\(stats.uploadCount) up") }
            if stats.downloadCount > 0 { parts.append("\(stats.downloadCount) down") }
            return parts.isEmpty ? "Syncing" : "Syncing · " + parts.joined(separator: ", ")
        }
        return "Up to date"
    }

    /// Text for a SyncError code that needs a step from the user, else the SDK text.
    static func describeError(_ code: Int, fallback: String) -> String {
        switch code {
        case 7, 40:
            return "MegaGlass cannot open this folder. Connect its disk or network, check that the folder was not "
                + "moved or renamed, and allow access in System Settings > Privacy & Security > Files and Folders."
        case 15: return "This folder is now on a different disk. Remove this sync and add it again to use the new disk."
        case 44: return "This folder was replaced by a different folder. Remove this sync and add it again."
        default: return fallback
        }
    }

    /// Why a folder cannot be the folder on this Mac of a sync or backup, or nil if it can.
    static func rootProblem(_ folder: URL, otherRoots: [String],
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            appFolders: [URL] = [AppPaths.support, AppPaths.caches]) -> String? {
        // Real path (symlinks, /tmp -> /private/tmp, letter case), compared without case.
        func key(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            if let real = realpath(path, nil) {
                path = String(cString: real)
                free(real)
            }
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path.precomposedStringWithCanonicalMapping.lowercased()
        }
        func isInside(_ path: String, _ folder: String) -> Bool {
            path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
        }
        let path = key(folder)
        let home = key(home)
        if path == home {
            return "Your whole home folder cannot be synced. Choose a folder in it, such as Documents."
        }
        let system = ["/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/private", "/dev", "/cores", "/opt"]
            .map { key(URL(filePath: $0)) } + [home + "/library"]
        // iCloud Drive and the folders of cloud apps (Dropbox, OneDrive, Google Drive) hold documents.
        let isCloudFolder = isInside(path, home + "/library/mobile documents/com~apple~clouddocs")
            || path.hasPrefix(home + "/library/cloudstorage/")
        // A folder that holds the home folder ("/", "/Users") counts as a system folder.
        if !isCloudFolder, isInside(home, path) || path == key(URL(filePath: "/Volumes")) || system.contains(where: { isInside(path, $0) }) {
            return "This is a system folder. Choose a folder in your home folder, such as Documents."
        }
        if appFolders.map(key).contains(where: { isInside(path, $0) || isInside($0, path) }) {
            return "This folder contains MegaGlass data. Choose another folder."
        }
        for root in otherRoots.map({ key(URL(filePath: $0)) }) {
            if isInside(path, root) { return "This folder is already in a sync or backup." }
            if isInside(root, path) { return "This folder contains a folder that is already in a sync or backup." }
        }
        return nil
    }

    static func describe(_ stall: MGSyncStall) -> String {
        describeStall(reason: stall.reason, problems: stall.pathProblems.map(\.intValue))
    }

    /// Text for a MegaSyncStall reason and its SyncPathProblem codes.
    static func describeStall(reason: Int, problems: [Int]) -> String {
        // DeletedOrMovedByUser and FileFolderDeletedByUser only tell what the user did.
        for problem in problems where problem != 14 && problem != 15 {
            switch problem {
            case 1: return "The file changes too often to sync."
            case 2: return "The .megaignore rules cannot be read."
            case 3: return "Hard links are not synced."
            case 4: return "Symbolic links are not synced."
            case 5: return "Special files are not synced."
            case 6: return "A different item with this name is already there."
            case 7: return "The parent folder does not exist."
            case 8: return "The disk reported an error."
            case 9: return "The name is too long for this disk."
            case 10: return "MegaGlass cannot read this file."
            case 11: return "Waiting for another issue to be solved."
            case 12: return "The downloaded file failed the integrity check."
            case 13: return "The download failed."
            case 16: return "The item cannot be moved to the .debris folder."
            case 17: return "The .megaignore file has an error."
            case 18: return "MegaGlass cannot read this folder. Check the disk or network connection, and allow access in System Settings > Privacy & Security."
            case 20: return "Waiting for the folder scan to finish."
            case 21: return "Waiting for another move to finish."
            case 22: return "The item was moved again before the move was done."
            case 23: return "This disk cannot store this name."
            case 24: return "The file in MEGA cannot be checked."
            case 25: return "The file in MEGA is blocked."
            case 26...29: return "Waiting for the upload to finish."
            case 30: return "Another disk is mounted in this folder. It is not synced."
            default: continue
            }
        }
        switch reason {
        case 2: return "The move or rename cannot be done on the other side."
        case 3: return "Waiting for the folder scan to finish."
        case 4: return "Waiting for moves to finish."
        case 5: return "The upload cannot be done."
        case 6: return "The download cannot be done."
        case 7: return "The folder cannot be made."
        case 8: return "The item cannot be deleted."
        case 9: return "The folder tree is too deep to sync."
        case 10: return "A file and a folder have the same name."
        case 11: return "The item changed on this Mac and in MEGA. Rename or remove one of them."
        case 12: return "The items on this Mac and in MEGA are different. Rename or remove one of them."
        case 13: return "Two items would get the same name. Rename one of them."
        default: return "This item cannot be synced."
        }
    }
}

/// The bridge calls these on the main queue.
private final class SyncRelay: NSObject, MGSyncControllerDelegate {
    weak var center: SyncCenter?

    func syncControllerDidChangeSyncs() { center?.reload() }
    func syncControllerDidUpdate(_ stats: MGSyncStats) { center?.update(stats) }
    func syncControllerDidChangeGlobalState() { center?.refreshGlobalState() }
}
