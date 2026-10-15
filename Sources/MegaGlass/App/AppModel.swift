import AppKit
import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let symbol: String
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Opens a preview window for one node of one engine.
struct PreviewRequest: Codable, Hashable {
    let engineID: String
    let handle: UInt64
    /// The media files of the folder, in browser order, for the viewer's previous and next.
    var siblings: [UInt64] = []
}

nonisolated private enum OperationContext {
    @TaskLocal static var sessionGeneration: UUID?
}

/// App-wide state and the node operations that views share.
@Observable
final class AppModel {
    let settings: AppSettings
    let engine: MegaEngine
    let session: Session
    let transfers: TransferCenter
    let syncs: SyncCenter
    let links: LinkCenter
    let bypass: BypassCenter
    let clipboard = ClipboardWatcher()

    var toast: Toast?
    var alert: AlertItem?
    /// A folder that the main window must show (for example after "Show in MEGA").
    var revealRequest: UInt64?
    var showOpenLinks = false
    /// Set by the transfer pill; the main window shows the transfers.
    var transfersRequested = false
    /// Set when links go to Bypass; the main window shows the Bypass section.
    var bypassRequested = false
    /// A link session that the main window must select after it opens.
    var linkToShow: UUID?
    /// Preview windows that stream from the local HTTP server.
    var streamingClients = 0

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        let settings = AppSettings()
        self.settings = settings
        let engine = MegaEngine(kind: .account, id: "account", basePath: AppPaths.accountEngine,
                                workerThreads: settings.workerThreads)
        self.engine = engine
        session = Session(engine: engine)
        transfers = TransferCenter(engine: engine)
        syncs = SyncCenter(engine: engine)
        links = LinkCenter()
        bypass = BypassCenter(settings: settings)

        session.onError = { [weak self] error in self?.show(error, title: "Session operation failed") }
        transfers.onError = { [weak self] error in self?.show(error, title: "Transfer operation failed") }
        bypass.onError = { [weak self] error in self?.show(error, title: "The API key was not saved") }
        transfers.applyLimits(settings)
        bypass.onLinks = { [weak self] links in
            guard let self else { return }
            let opened = self.links.open(text: links.joined(separator: "\n"), account: engine, workerThreads: settings.workerThreads)
            linkToShow = opened.first?.id
            notify(opened.count == 1 ? "Opened 1 MEGA link" : "Opened \(opened.count) MEGA links", symbol: "link")
        }
        bypass.onNeedsYou = { [weak self] host in
            // Only after every automatic service failed.
            self?.notify("Bypass needs you for \(host)", symbol: "hand.raised")
            self?.bypassRequested = true
            NSApp.requestUserAttention(.informationalRequest)
        }
        clipboard.onText = { [weak self] text in
            self?.handleIncoming(text, source: .clipboard)
        }
        clipboard.setEnabled(settings.clipboardWatch)
        session.onSignedIn = { [weak self] in
            guard let self else { return }
            syncs.reload()
            Task { await self.transfers.loadExisting() }
        }
        session.onSignedOut = { [weak self] in
            self?.syncs.reload()
            self?.transfers.reset()
        }
        transfers.onFinished = { [weak self] item in
            if item.state == .failed, let message = item.errorMessage {
                self?.notify("\(item.name): \(message)", symbol: "exclamationmark.triangle")
            }
        }
    }

    func startOnce() async {
        guard !started else { return }
        started = true
        // Recover plaintext cache leftovers from a crash before starting any writers.
        AppPaths.removeAll(at: AppPaths.previews)
        links.restore(account: engine, workerThreads: settings.workerThreads)
        await session.start()
        // Without an account, the restored links open as a guest.
        if !session.isSignedIn, !links.sessions.isEmpty { session.isGuest = true }
    }

    func engine(id: String) -> MegaEngine? {
        if id == engine.id { return engine }
        return links.sessions.compactMap(\.engine).first { $0.id == id }
    }

    // MARK: Feedback

    func notify(_ text: String, symbol: String = "checkmark.circle") {
        toastTask?.cancel()
        toast = Toast(text: text, symbol: symbol)
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func show(_ error: any Error, title: String = "The action failed") {
        alert = AlertItem(title: title, message: error.localizedDescription)
    }

    @discardableResult
    private func perform(_ title: String, _ work: () async throws -> Void) async -> Bool {
        let generation = session.generation
        return await OperationContext.$sessionGeneration.withValue(generation) {
            do {
                try validateOperation()
                try await work()
                try validateOperation()
                return true
            } catch is CancellationError {
                return false
            } catch {
                show(error, title: title)
                return false
            }
        }
    }

    private func validateOperation() throws {
        try Task.checkCancellation()
        if let generation = OperationContext.sessionGeneration {
            guard generation == session.generation, session.isSignedIn, !session.isSigningOut else {
                throw CancellationError()
            }
        }
    }

    private func requiredNode(_ handle: UInt64, in source: MegaEngine) throws -> MEGANode {
        try validateOperation()
        guard let node = source.node(handle) else {
            throw MegaFailure(code: -9, message: "The item is no longer available. Refresh and try again.")
        }
        return node
    }

    func shutdown() {
        clipboard.setEnabled(false)
        bypass.shutdown()
        transfers.shutdown()
        syncs.shutdown()
        engine.shutdown()
        for link in links.sessions { link.close() }
        // Preview files are cleaned at the next cold start, after all old writers exit.
    }

    // MARK: Links

    func openLinks(_ text: String) -> [LinkSession] {
        let opened = links.open(text: text, account: engine, workerThreads: settings.workerThreads)
        if opened.isEmpty {
            alert = AlertItem(title: "No MEGA link found", message: "Paste one or more file or folder links, one for each line.")
        }
        linkToShow = opened.first?.id
        return opened
    }

    enum LinkSource { case clipboard, bookmarklet, scheme, drop, paste }

    /// Entry point for links from outside: MEGA links open, protector links go to Bypass.
    /// `forceBypass` sends every non-MEGA web link to Bypass (explicit requests).
    func handleIncoming(_ text: String, source: LinkSource, forceBypass: Bool = false) {
        let sorted = LinkSorter.sort(text, protectorHosts: Set(settings.protectorHosts), allWebLinks: forceBypass)
        guard !sorted.isEmpty else {
            if source != .clipboard {
                alert = AlertItem(title: "No MEGA link found",
                                  message: "There are no MEGA links or link-protector links in the text.")
            }
            return
        }
        if !sorted.mega.isEmpty {
            let opened = links.open(text: sorted.mega.joined(separator: "\n"), account: engine, workerThreads: settings.workerThreads)
            linkToShow = opened.first?.id
        }
        if !sorted.protected.isEmpty {
            bypass.enqueue(sorted.protected)
            if sorted.mega.isEmpty { bypassRequested = true }
        }
        var parts: [String] = []
        if !sorted.mega.isEmpty { parts.append(sorted.mega.count == 1 ? "1 MEGA link" : "\(sorted.mega.count) MEGA links") }
        if !sorted.protected.isEmpty { parts.append(sorted.protected.count == 1 ? "1 link to bypass" : "\(sorted.protected.count) links to bypass") }
        notify(parts.joined(separator: ", "), symbol: source == .clipboard ? "doc.on.clipboard" : "link")
        if source != .paste { NSApp.activate() }
    }

    // MARK: Transfers

    func download(_ handles: [UInt64], from source: MegaEngine) {
        guard !handles.isEmpty, let folder = downloadFolder() else { return }
        let sdk = engine.sdk
        let target = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let generation = session.generation
        Task {
            let nodes = await EngineQueue.run {
                handles.compactMap { source.node($0) }.map { node in
                    source === self.engine ? node : (source.sdk.authorizeNode(node) ?? node)
                }
            }
            guard source !== self.engine || (generation == session.generation && session.isSignedIn && !session.isSigningOut) else { return }
            for node in nodes {
                sdk.startDownloadNode(node, localPath: target, fileName: nil, appData: nil, startFirst: false,
                                      cancelToken: nil, collisionCheck: .fingerprint, collisionResolution: .newWithN)
            }
            notify(nodes.count == 1 ? "Downloading \(nodes[0].name ?? "item")" : "Downloading \(nodes.count) items",
                   symbol: "arrow.down.circle")
        }
    }

    /// Downloads a public file node (from a file link).
    func download(publicNode node: MEGANode) {
        guard let folder = downloadFolder() else { return }
        let target = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        engine.sdk.startDownloadNode(node, localPath: target, fileName: nil, appData: nil, startFirst: false,
                                     cancelToken: nil, collisionCheck: .fingerprint, collisionResolution: .newWithN)
        notify("Downloading \(node.name ?? "file")", symbol: "arrow.down.circle")
    }

    private func downloadFolder() -> URL? {
        let folder: URL
        if settings.askWhereToDownload {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Download Here"
            panel.directoryURL = settings.downloadFolder
            guard panel.runModal() == .OK, let selected = panel.url else { return nil }
            folder = selected
        } else {
            folder = settings.downloadFolder
        }
        do { try LocalFileSafety.validateDownloadDirectory(folder); return folder }
        catch { show(error, title: "The download folder is unavailable"); return nil }
    }

    func upload(_ urls: [URL], to folder: UInt64) {
        guard !urls.isEmpty, let parent = engine.node(folder) else { return }
        guard urls.allSatisfy({ $0.isFileURL }) else {
            show(CocoaError(.fileReadUnsupportedScheme), title: "Choose local files to upload")
            return
        }
        for url in urls {
            engine.sdk.startUpload(withLocalPath: url.path, parent: parent, cancelToken: nil, options: MEGAUploadOptions())
        }
        notify(urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)" : "Uploading \(urls.count) items",
               symbol: "arrow.up.circle")
    }

    func chooseAndUpload(to folder: UInt64, folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, to: folder)
    }

    // MARK: Node operations

    func createFolder(named name: String, in folder: UInt64, engine source: MegaEngine) async {
        await perform("The folder was not created") {
            let parent = try requiredNode(folder, in: source)
            let sdk = source.sdk
            try validateOperation()
            _ = try await sdk.request { sdk.createFolder(withName: name, parent: parent, delegate: $0) }
        }
    }

    func rename(_ handle: UInt64, to name: String, engine source: MegaEngine) async {
        await perform("The item was not renamed") {
            let node = try requiredNode(handle, in: source)
            let sdk = source.sdk
            try validateOperation()
            _ = try await sdk.request { sdk.renameNode(node, newName: name, delegate: $0) }
        }
    }

    func moveToRubbish(_ handles: [UInt64]) async {
        guard let rubbish = engine.sdk.rubbishNode else { return }
        guard await move(handles, to: rubbish.handle, quiet: true) else { return }
        notify(handles.count == 1 ? "Moved to Rubbish Bin" : "Moved \(handles.count) items to Rubbish Bin", symbol: "trash")
    }

    func deletePermanently(_ handles: [UInt64], engine source: MegaEngine) async {
        await perform("The item was not deleted") {
            let sdk = source.sdk
            for node in try handles.map({ try requiredNode($0, in: source) }) {
                try validateOperation()
                _ = try await sdk.request { sdk.remove(node, delegate: $0) }
            }
        }
    }

    /// Moves items from the Rubbish Bin back to where they were.
    func restore(_ items: [NodeItem]) async {
        let sdk = engine.sdk
        let succeeded = await perform("The item was not restored") {
            for item in items {
                let node = try requiredNode(item.id, in: engine)
                let target = engine.node(item.restoreHandle).flatMap { sdk.isNode(inRubbish: $0) ? nil : $0 } ?? sdk.rootNode
                guard let target else { throw MegaFailure(code: -9, message: "The destination is unavailable.") }
                try validateOperation()
                _ = try await sdk.request { sdk.move(node, newParent: target, delegate: $0) }
            }
        }
        guard succeeded else { return }
        notify("Restored", symbol: "arrow.uturn.backward")
    }

    @discardableResult
    func move(_ handles: [UInt64], to folder: UInt64, quiet: Bool = false) async -> Bool {
        let sdk = engine.sdk
        let succeeded = await perform("The item was not moved") {
            let target = try requiredNode(folder, in: engine)
            for node in try handles.map({ try requiredNode($0, in: engine) }) where node.handle != folder {
                try validateOperation()
                _ = try await sdk.request { sdk.move(node, newParent: target, delegate: $0) }
            }
        }
        if succeeded, !quiet { notify("Moved", symbol: "folder") }
        return succeeded
    }

    /// Copies inside the account, or imports from an open folder link.
    func copy(_ handles: [UInt64], from source: MegaEngine, to folder: UInt64) async {
        let sdk = engine.sdk
        let succeeded = await perform(source === engine ? "The item was not copied" : "The item was not imported") {
            let target = try requiredNode(folder, in: engine)
            for handle in handles {
                var node = try requiredNode(handle, in: source)
                if source !== engine {
                    guard let authorized = source.sdk.authorizeNode(node) else { throw MegaFailure(code: -11, message: "This link no longer allows importing the item.") }
                    node = authorized
                }
                try validateOperation()
                _ = try await sdk.request { sdk.copy(node, newParent: target, delegate: $0) }
            }
        }
        guard succeeded else { return }
        notify(source === engine ? "Copied" : "Imported to your Cloud Drive", symbol: "doc.on.doc")
    }

    func importPublicNode(_ node: MEGANode, to folder: UInt64) async {
        let sdk = engine.sdk
        await perform("The file was not imported") {
            let target = try requiredNode(folder, in: engine)
            try validateOperation()
            _ = try await sdk.request { sdk.copy(node, newParent: target, delegate: $0) }
            notify("Imported to your Cloud Drive", symbol: "square.and.arrow.down")
        }
    }

    /// Makes public links and puts them on the pasteboard, one for each line.
    func copyLinks(_ handles: [UInt64], expires: Date? = nil) async {
        let sdk = engine.sdk
        var result: [String] = []
        let succeeded = await perform("The link was not created") {
            for node in try handles.map({ try requiredNode($0, in: engine) }) {
                try validateOperation()
                let request = try await sdk.request { delegate in
                    if let expires {
                        sdk.export(node, expireTime: expires, delegate: delegate)
                    } else {
                        sdk.export(node, delegate: delegate)
                    }
                }
                if let link = request.link { result.append(link) }
            }
        }
        guard succeeded, !result.isEmpty else { return }
        Pasteboard.copy(result.joined(separator: "\n"))
        notify(result.count == 1 ? "Link copied" : "\(result.count) links copied", symbol: "link")
    }

    func protectLink(_ link: String, password: String) async -> String? {
        let sdk = engine.sdk
        do {
            return try await sdk.request { sdk.encryptLink(withPassword: link, password: password, delegate: $0) }.text
        } catch {
            show(error, title: "The link was not protected")
            return nil
        }
    }

    func removeLinks(_ handles: [UInt64]) async {
        let sdk = engine.sdk
        let succeeded = await perform("The link was not removed") {
            for node in try handles.map({ try requiredNode($0, in: engine) }) {
                try validateOperation()
                _ = try await sdk.request { sdk.disableExport(node, delegate: $0) }
            }
        }
        guard succeeded else { return }
        notify("Link removed", symbol: "link.badge.plus")
    }

    func share(_ folder: UInt64, with email: String, access: MEGAShareType) async {
        let sdk = engine.sdk
        await perform("The folder was not shared") {
            guard let node = engine.node(folder) else { return }
            try validateOperation()
            _ = try await sdk.request { sdk.share(node, withEmail: email, level: access.rawValue, delegate: $0) }
            notify(access == .accessUnknown ? "Access removed" : "Shared with \(email)", symbol: "person.2")
        }
    }

    func setLabel(_ handles: [UInt64], _ label: NodeLabel) async {
        let sdk = engine.sdk
        await perform("The label was not changed") {
            for node in try handles.map({ try requiredNode($0, in: engine) }) {
                if label == .none {
                    try validateOperation()
                _ = try await sdk.request { sdk.resetNodeLabel(node, delegate: $0) }
                } else {
                    let value = MEGANodeLabel(rawValue: label.rawValue) ?? .unknown
                    try validateOperation()
                _ = try await sdk.request { sdk.setNodeLabel(node, label: value, delegate: $0) }
                }
            }
        }
    }

    func setFavourite(_ handles: [UInt64], _ favourite: Bool) async {
        let sdk = engine.sdk
        await perform("The favourite was not changed") {
            for node in try handles.map({ try requiredNode($0, in: engine) }) {
                try validateOperation()
                _ = try await sdk.request { sdk.setNodeFavourite(node, favourite: favourite, delegate: $0) }
            }
        }
    }

    func emptyRubbishBin() async {
        let sdk = engine.sdk
        await perform("The Rubbish Bin was not emptied") {
            try validateOperation()
            _ = try await sdk.request { sdk.cleanRubbishBin(with: $0) }
            notify("Rubbish Bin emptied", symbol: "trash.slash")
        }
        await session.refreshAccount()
    }
}
