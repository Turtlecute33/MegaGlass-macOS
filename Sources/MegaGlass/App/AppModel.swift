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

/// The account reloads (the engine asked for it): an action stops between two steps.
nonisolated private struct AccountReloading: LocalizedError {
    var errorDescription: String? {
        "The account was reloading, so the action stopped. Some items can be done already: check them, then try again."
    }
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
    /// Many links from a copy or from another app: they open after you say yes.
    var pendingLinks: PendingLinks?
    /// Preview windows that stream from the local HTTP server.
    var streamingClients = 0
    /// Open preview windows for each engine ID. A folder link with one keeps its engine.
    @ObservationIgnored var previewEngines: [String: Int] = [:]
    /// Opens the main window, or brings it to the front (set by the app menus).
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var schemeLinks = LinkSorter.Result()
    @ObservationIgnored private var schemeTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    init() {
        // The files and folders inside a folder download get clean names, as single downloads do.
        MEGASdk.setFolderDownloadNameFilter { LocalFileSafety.filename($0) }
        let settings = AppSettings()
        self.settings = settings
        let engine = MegaEngine(kind: .account, id: "account", basePath: AppPaths.accountEngine,
                                workerThreads: settings.workerThreads)
        self.engine = engine
        session = Session(engine: engine, localCache: AppPaths.accountEngine)
        transfers = TransferCenter(engine: engine)
        syncs = SyncCenter(engine: engine)
        links = LinkCenter()
        bypass = BypassCenter(settings: settings)
        links.isInUse = { [weak self] id in (self?.previewEngines[id] ?? 0) > 0 }

        session.onError = { [weak self] error in self?.show(error, title: "Session operation failed") }
        transfers.onError = { [weak self] error in self?.show(error, title: "Transfer operation failed") }
        bypass.onError = { [weak self] error, title in self?.show(error, title: title) }
        transfers.applyLimits(settings)
        bypass.onLinks = { [weak self] links, all in
            Task { [weak self] in
                guard let self else { return }
                let keep = all || settings.bypassKeepLargest == 0 ? LinkCenter.openLimit : settings.bypassKeepLargest
                let chosen = await LinkCenter.largest(links, count: keep, sdk: engine.sdk)
                let shown = chosen.links.prefix(LinkCenter.openLimit)
                // In the background: the window stays on Bypass while the links open.
                let opened = self.links.open(text: shown.joined(separator: "\n"), account: engine, workerThreads: settings.workerThreads)
                notify(Self.bypassOpenedText(links: links, shown: Array(shown), opened: opened.count, bySize: chosen.bySize),
                       symbol: "link")
            }
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
        clipboard.onDenied = { [weak self] in
            self?.alert = AlertItem(title: "MegaGlass cannot read copied links",
                                    message: "macOS denies MegaGlass access to the clipboard. Allow it in System Settings > Privacy & Security > Paste from Other Apps, or turn off “Open copied MEGA and protector links” in Settings > Links.")
        }
        clipboard.setEnabled(settings.clipboardWatch)
        BrowserRouter.rememberDefault(in: settings)
        session.onSignedIn = { [weak self] in
            guard let self else { return }
            syncs.reload()
            Task { await self.transfers.loadExisting() }
        }
        session.onSignedOut = { [weak self] in
            self?.syncs.reload()
            self?.transfers.reset()
        }
        session.onSessionEnded = { [weak self] in self?.showMainWindow() }
        transfers.onFinished = { [weak self] item in
            if item.state == .failed, let message = item.errorMessage {
                self?.notify("\(item.name): \(message)", symbol: "exclamationmark.triangle")
            }
        }
        engine.onAccountNotice = { [weak self] reason in
            let title = "Your MEGA account needs verification"
            // Each failed request can repeat the notice: one alert at a time.
            guard let self, alert?.title != title else { return }
            alert = AlertItem(title: title,
                              message: reason ?? "MEGA suspended your account until you verify it. Follow the steps in the email from MEGA.")
            showMainWindow()
        }
        engine.onFatalError = { [weak self] reason in
            guard let self, let message = MegaFailure.fatalErrorMessage(reason: reason) else { return }
            alert = AlertItem(title: "Syncs stopped", message: message)
            showMainWindow()
        }
        trackActivity()
    }

    /// Transfers and syncs go on when the app has no window: App Nap must not slow them.
    /// The Mac can still go to sleep.
    private func trackActivity() {
        let busy = withObservationTracking {
            transfers.hasActivity || syncs.isSyncing
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackActivity() }
        }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "MEGA transfers and syncs")
        } else if !busy, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func startOnce() async {
        guard !started else { return }
        started = true
        // Recover plaintext cache leftovers from a crash before starting any writers.
        AppPaths.removeAll(at: AppPaths.previews)
        links.restore(account: engine, workerThreads: settings.workerThreads)
        await session.start()
        // Without an account, the restored links open as a guest; say why the login failed.
        if !session.isSignedIn, !links.sessions.isEmpty {
            session.isGuest = true
            if let message = session.startupMessage { alert = AlertItem(title: "You are not logged in", message: message) }
        }
    }

    /// The toast after Bypass opens `opened` links: `shown` of the `links` it found.
    static func bypassOpenedText(links: [String], shown: [String], opened: Int, bySize: Bool) -> String {
        guard shown.count < links.count else {
            return opened == 1 ? "1 MEGA link opens in Open Links" : "\(opened) MEGA links open in Open Links"
        }
        guard bySize else { return "\(opened) of \(links.count) MEGA links open in Open Links" }
        // Links with a password have no size: they open apart from the largest.
        let locked = shown.count(where: LinkParser.isPasswordProtected)
        return "The \(opened - locked) largest of \(links.count - locked) MEGA links"
            + (locked > 0 ? ", and \(locked) with a password," : "") + " open in Open Links"
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

    /// Requests, toasts and alerts show in the main window: it opens when it is closed.
    func showMainWindow() {
        openMainWindow?()
        NSApp.activate()
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
            // After a logout or another login, the action stops with no message.
            guard generation == session.generation, !session.isSigningOut, session.phase != .signedOut else {
                throw CancellationError()
            }
            guard session.isSignedIn else { throw AccountReloading() }
        }
    }

    /// Node reads take the engine lock: they run on the engine read queue.
    private func requiredNode(_ handle: UInt64, in source: MegaEngine) async throws -> MEGANode {
        try validateOperation()
        guard let node = await source.sdk.loadNode(handle) else {
            throw MegaFailure(code: -9, message: "The item is no longer available. Refresh and try again.")
        }
        try validateOperation()
        return node
    }

    private func requiredNodes(_ handles: [UInt64], in source: MegaEngine) async throws -> [MEGANode] {
        var nodes: [MEGANode] = []
        for handle in handles { nodes.append(try await requiredNode(handle, in: source)) }
        return nodes
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

    enum LinkSource { case clipboard, scheme, drop, paste }

    struct PendingLinks {
        let sorted: LinkSorter.Result
        let source: LinkSource
    }

    /// Entry point for links from outside: MEGA links open, protector links go to Bypass.
    /// `forceBypass` sends every non-MEGA web link to Bypass (explicit requests).
    func handleIncoming(_ text: String, source: LinkSource, forceBypass: Bool = false) {
        handleIncoming(LinkSorter.sort(text, protectorHosts: Set(settings.protectorHosts), allWebLinks: forceBypass),
                       source: source)
    }

    /// `confirmed`: you said yes to many links from a copy or from another app.
    func handleIncoming(_ sorted: LinkSorter.Result, source: LinkSource, confirmed: Bool = false) {
        guard !sorted.isEmpty else {
            if source != .clipboard {
                alert = AlertItem(title: "No MEGA link found",
                                  message: "There are no MEGA links or link-protector links in the text.")
                if source == .scheme { showMainWindow() }
            }
            return
        }
        // Links that are open already do not count: the same text again opens the next ones.
        let open = Set(links.sessions.map { LinkParser.identity(of: $0.link) })
        var fresh = sorted
        fresh.mega = sorted.mega.filter { !open.contains(LinkParser.identity(of: $0)) }
        if !confirmed, source == .clipboard || source == .scheme, fresh.mega.count > LinkCenter.askAbove {
            pendingLinks = PendingLinks(sorted: fresh, source: source)
            showMainWindow()
            return
        }
        let mega = Array(fresh.mega.prefix(LinkCenter.openLimit))
        if let first = sorted.mega.first {
            if mega.isEmpty {
                linkToShow = links.sessions.first { LinkParser.identity(of: $0.link) == LinkParser.identity(of: first) }?.id
            } else {
                let opened = links.open(text: mega.joined(separator: "\n"), account: engine, workerThreads: settings.workerThreads)
                linkToShow = opened.first?.id
            }
            // With no account, the links show in guest mode, not behind the login screen.
            if session.phase == .signedOut, linkToShow != nil { session.isGuest = true }
        }
        if mega.count < fresh.mega.count, !confirmed {
            alert = AlertItem(title: "\(mega.count) of \(fresh.mega.count) new MEGA links open",
                              message: "One action opens up to \(LinkCenter.openLimit) links. To open the others, paste them in Open Links.")
        }
        if !sorted.protected.isEmpty {
            bypass.enqueue(sorted.protected)
            if sorted.mega.isEmpty { bypassRequested = true }
        }
        var parts: [String] = []
        if !mega.isEmpty { parts.append(mega.count == 1 ? "1 MEGA link" : "\(mega.count) MEGA links") }
        else if !sorted.mega.isEmpty { parts.append(sorted.mega.count == 1 ? "The MEGA link is open already" : "The MEGA links are open already") }
        if !sorted.protected.isEmpty { parts.append(sorted.protected.count == 1 ? "1 link to bypass" : "\(sorted.protected.count) links to bypass") }
        notify(parts.joined(separator: ", "), symbol: source == .clipboard ? "doc.on.clipboard" : "link")
        if source != .paste { showMainWindow() }
    }

    /// Links from another app. A web page sends each mega:// link as its own event: the links
    /// of events less than half a second apart count together, for the question and the limit.
    func receiveFromOtherApp(_ sorted: LinkSorter.Result) {
        schemeLinks.add(sorted)
        schemeTask?.cancel()
        schemeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let links = schemeLinks
            schemeLinks = LinkSorter.Result()
            schemeTask = nil
            handleIncoming(links, source: .scheme)
        }
    }

    /// The menu command reads the clipboard itself: macOS can ask first, or deny it.
    func openLinksFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            handleIncoming(text, source: .paste)
        } else {
            alert = AlertItem(title: "No text from the clipboard",
                              message: NSPasteboard.general.accessBehavior == .alwaysDeny
                                  ? "macOS denies MegaGlass access to the clipboard. Paste the links in Open Links, or allow MegaGlass in System Settings > Privacy & Security > Paste from Other Apps."
                                  : "The clipboard has no text, or macOS did not allow MegaGlass to read it. You can paste the links in Open Links.")
        }
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
            if source === self.engine {
                guard generation == session.generation, !session.isSigningOut, session.phase != .signedOut else { return }
                guard session.isSignedIn else { show(AccountReloading(), title: "The download did not start"); return }
            }
            guard !nodes.isEmpty else {
                show(MegaFailure(code: -9, message: "The items are no longer available. Refresh and try again."),
                     title: "The download did not start")
                return
            }
            for node in nodes {
                sdk.startDownloadNode(node, localPath: target, fileName: node.name.map(LocalFileSafety.filename),
                                      appData: nil, startFirst: false, cancelToken: nil,
                                      collisionCheck: .fingerprint, collisionResolution: .newWithN)
            }
            notify(nodes.count == 1 ? "Downloading \(LocalFileSafety.displayName(nodes[0].name ?? "item"))"
                   : "Downloading \(nodes.count) items", symbol: "arrow.down.circle")
        }
    }

    /// Downloads a public file node (from a file link).
    func download(publicNode node: MEGANode) {
        guard let folder = downloadFolder() else { return }
        let target = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        engine.sdk.startDownloadNode(node, localPath: target, fileName: node.name.map(LocalFileSafety.filename),
                                     appData: nil, startFirst: false, cancelToken: nil,
                                     collisionCheck: .fingerprint, collisionResolution: .newWithN)
        notify("Downloading \(LocalFileSafety.displayName(node.name ?? "file"))", symbol: "arrow.down.circle")
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
        guard !urls.isEmpty else { return }
        guard urls.allSatisfy({ $0.isFileURL }) else {
            show(CocoaError(.fileReadUnsupportedScheme), title: "Choose local files to upload")
            return
        }
        let sdk = engine.sdk
        let paths = urls.map(\.path)
        Task {
            guard let parent = await sdk.loadNode(folder) else {
                show(MegaFailure(code: -9, message: "The folder is no longer available. Refresh and try again."),
                     title: "The upload did not start")
                return
            }
            // The engine reads each file (its fingerprint) before the upload starts: slow
            // disks and iCloud files must not block the main thread.
            await EngineQueue.run {
                for path in paths {
                    sdk.startUpload(withLocalPath: path, parent: parent, cancelToken: nil, options: MEGAUploadOptions())
                }
            }
            notify(urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)" : "Uploading \(urls.count) items",
                   symbol: "arrow.up.circle")
        }
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
            let parent = try await requiredNode(folder, in: source)
            let sdk = source.sdk
            try validateOperation()
            _ = try await sdk.request { sdk.createFolder(withName: name, parent: parent, delegate: $0) }
        }
    }

    func rename(_ handle: UInt64, to name: String, engine source: MegaEngine) async {
        await perform("The item was not renamed") {
            let node = try await requiredNode(handle, in: source)
            let sdk = source.sdk
            try validateOperation()
            _ = try await sdk.request { sdk.renameNode(node, newName: name, delegate: $0) }
        }
    }

    func moveToRubbish(_ handles: [UInt64]) async {
        let sdk = engine.sdk
        guard let rubbish = await EngineQueue.run({ sdk.rubbishNode?.handle }) else { return }
        guard await move(handles, to: rubbish, quiet: true) else { return }
        notify(handles.count == 1 ? "Moved to Rubbish Bin" : "Moved \(handles.count) items to Rubbish Bin", symbol: "trash")
    }

    func deletePermanently(_ handles: [UInt64], engine source: MegaEngine) async {
        await perform("The item was not deleted") {
            let sdk = source.sdk
            for node in try await requiredNodes(handles, in: source) {
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
                let node = try await requiredNode(item.id, in: engine)
                let previous = item.restoreHandle
                let target = await EngineQueue.run {
                    sdk.node(forHandle: previous).flatMap { sdk.isNode(inRubbish: $0) ? nil : $0 } ?? sdk.rootNode
                }
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
            let target = try await requiredNode(folder, in: engine)
            for node in try await requiredNodes(handles, in: engine) where node.handle != folder {
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
            let target = try await requiredNode(folder, in: engine)
            for handle in handles {
                var node = try await requiredNode(handle, in: source)
                if source !== engine {
                    let link = source.sdk
                    let original = node
                    guard let authorized = await EngineQueue.run({ link.authorizeNode(original) }) else { throw MegaFailure(code: -11, message: "This link no longer allows importing the item.") }
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
            let target = try await requiredNode(folder, in: engine)
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
            for node in try await requiredNodes(handles, in: engine) {
                try validateOperation()
                let request = try await sdk.request { delegate in
                    if let expires {
                        sdk.export(node, expireTime: expires, delegate: delegate)
                    } else {
                        sdk.export(node, delegate: delegate)
                    }
                }
                guard let link = request.link else {
                    throw MegaFailure(code: -9, message: "MEGA did not return a link for “\(LocalFileSafety.displayName(node.name ?? "the item"))”.")
                }
                result.append(link)
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
            for node in try await requiredNodes(handles, in: engine) {
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
            let node = try await requiredNode(folder, in: engine)
            try validateOperation()
            _ = try await sdk.request { sdk.share(node, withEmail: email, level: access.rawValue, delegate: $0) }
            notify(access == .accessUnknown ? "Access removed" : "Shared with \(email)", symbol: "person.2")
        }
    }

    func setLabel(_ handles: [UInt64], _ label: NodeLabel) async {
        let sdk = engine.sdk
        await perform("The label was not changed") {
            for node in try await requiredNodes(handles, in: engine) {
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
            for node in try await requiredNodes(handles, in: engine) {
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
