import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

/// One open MEGA link. Folder links get their own engine instance, so many links can
/// be open at the same time, next to the account.
@Observable
final class LinkSession: Identifiable {
    enum Kind { case file, folder }
    enum State: Equatable {
        /// Not opened yet. A folder link opens (and starts its engine) when you select it.
        case idle
        case opening
        case needsPassword
        case ready
        case failed(String)
    }

    /// Stays the same after a restart: the engine folder and preview windows use it.
    let id: UUID
    let link: String
    private(set) var kind: Kind
    private(set) var state: State = .idle
    private(set) var title: String
    /// The size of the file, or of the folder with all its subfolders.
    private(set) var totalSize: Int64?
    /// For file links.
    private(set) var fileNode: MEGANode?
    private(set) var fileItem: NodeItem?
    /// The decrypted thumbnail and preview of a file link, apart from the account's.
    private(set) var fileThumbnails: ThumbnailStore?
    /// For folder links.
    private(set) var engine: MegaEngine?
    private(set) var browser: BrowserModel?

    @ObservationIgnored private var closed = false
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    /// The logout of an engine that `suspend` stopped: a new engine waits for it.
    @ObservationIgnored private var suspending: Task<Void, Never>?
    @ObservationIgnored private var resolvedLink: String
    /// Called before a folder link starts its engine (LinkCenter limits the engines).
    @ObservationIgnored var willStartEngine: ((LinkSession) -> Void)?

    init(link: String, kind: Kind, id: UUID = UUID()) {
        self.id = id
        self.link = link
        self.kind = kind
        resolvedLink = link
        title = kind == .folder ? "Folder link" : "File link"
    }

    var symbol: String {
        switch state {
        case .failed: "exclamationmark.triangle"
        case .needsPassword: "lock"
        default: kind == .folder ? "folder.badge.gearshape" : "doc"
        }
    }

    /// A file link opens at once: one small request to the account engine. A folder link
    /// gets only its name and size; its engine starts when you select it.
    func prepare(using account: MegaEngine, workerThreads: Int) {
        guard kind == .folder, !LinkParser.isPasswordProtected(resolvedLink) else {
            beginOpen(using: account, workerThreads: workerThreads)
            return
        }
        guard !closed, state == .idle, peekTask == nil else { return }
        let sdk = account.sdk
        let link = resolvedLink
        peekTask = Task {
            defer { peekTask = nil }
            let request = try? await sdk.request { sdk.getPublicLinkInformation(withFolderLink: link, delegate: $0) }
            guard let request, !closed, state == .idle else { return }
            if let name = request.text, !name.isEmpty { title = LocalFileSafety.displayName(name) }
            totalSize = request.megaFolderInfo?.currentSize
        }
    }

    func beginOpen(using account: MegaEngine, workerThreads: Int) {
        guard !closed, openingTask == nil else { return }
        run { await self.open(using: account, workerThreads: workerThreads) }
    }

    /// The opening task. `suspend` can cancel it and a new one can start before it ends.
    @discardableResult
    private func run(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let task = Task { await work() }
        openingTask = task
        Task {
            await task.value
            if openingTask == task { openingTask = nil }
        }
        return task
    }

    func open(using account: MegaEngine, workerThreads: Int) async {
        guard !closed, !Task.isCancelled else { return }
        state = .opening
        if LinkParser.isPasswordProtected(resolvedLink) {
            state = .needsPassword
            return
        }
        do {
            switch kind {
            case .file:
                let sdk = account.sdk
                let link = resolvedLink
                let request = try await sdk.request { sdk.publicNode(forMegaFileLink: link, delegate: $0) }
                guard !closed, !Task.isCancelled else { return }
                guard let node = request.publicNode else { throw MegaFailure(code: -9, message: "The link is not valid.") }
                fileNode = node
                fileItem = NodeItem(node)
                if fileThumbnails == nil {
                    fileThumbnails = ThumbnailStore(sdk: sdk, directory: AppPaths.thumbnails("link-" + id.uuidString))
                }
                totalSize = fileItem?.size
                title = LocalFileSafety.displayName(node.name ?? title)
            case .folder:
                if let old = engine {
                    // A failed attempt: its engine closes before a new one uses the same folder.
                    self.engine = nil
                    old.shutdown()
                    let oldSdk = old.sdk
                    _ = try? await oldSdk.request(accepting: [.apiESid]) { oldSdk.localLogout(with: $0) }
                    guard !closed, !Task.isCancelled else { return }
                }
                // The logout of a stopped engine of this link ends before a new one uses its folder.
                if let suspending {
                    await suspending.value
                    guard !closed, !Task.isCancelled else { return }
                }
                willStartEngine?(self)
                let engine = MegaEngine(kind: .folderLink,
                                        id: "link-" + id.uuidString,
                                        basePath: AppPaths.linkEngine(id.uuidString),
                                        workerThreads: min(workerThreads, 2))
                self.engine = engine
                let sdk = engine.sdk
                let link = resolvedLink
                _ = try await sdk.request { sdk.login(toFolderLink: link, delegate: $0) }
                guard !closed, !Task.isCancelled else { return }
                _ = try await sdk.request { sdk.fetchNodes(with: $0) }
                guard !closed, !Task.isCancelled else { return }
                guard let root = sdk.rootNode else { throw MegaFailure(code: -9, message: "The folder is not available.") }
                title = LocalFileSafety.displayName(root.name ?? title)
                // The size of the tree takes the engine lock: not on the main thread.
                let rootHandle = root.handle
                totalSize = await EngineQueue.run { sdk.node(forHandle: rootHandle).map { sdk.size(for: $0).int64Value } }
                guard !closed, !Task.isCancelled else { return }
                // Open links show the largest items first.
                browser = BrowserModel(engine: engine, start: .folder(root.handle), rootTitle: title,
                                       sortKey: .size, ascending: false)
            }
            state = .ready
        } catch {
            guard !closed, !Task.isCancelled else { return }
            if (error as? MegaFailure)?.code == MEGAErrorType.apiEIncomplete.rawValue {
                state = .failed("The link has no decryption key. Open the link again with its key (after #).")
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func unlock(password: String, using account: MegaEngine, workerThreads: Int) async {
        guard !closed, openingTask == nil else { return }
        await run { await self.unlockLink(password: password, using: account, workerThreads: workerThreads) }.value
    }

    private func unlockLink(password: String, using account: MegaEngine, workerThreads: Int) async {
        guard !closed else { return }
        let sdk = account.sdk
        let link = resolvedLink
        do {
            let request = try await sdk.request { sdk.decryptPasswordProtectedLink(link, password: password, delegate: $0) }
            guard !closed, !Task.isCancelled else { return }
            guard let plain = request.text else { throw MegaFailure(code: -14, message: "The password is not correct.") }
            resolvedLink = plain
            kind = LinkParser.kind(of: plain)
            await open(using: account, workerThreads: workerThreads)
        } catch {
            state = .needsPassword
            title = "Wrong password"
        }
    }

    /// Stops the engine of a folder link and keeps its cache: the link opens again when you
    /// select it.
    func suspend() {
        guard !closed, let engine else { return }
        openingTask?.cancel()
        openingTask = nil
        browser?.stop()
        browser = nil
        self.engine = nil
        state = .idle
        engine.shutdown()
        let sdk = engine.sdk
        let previous = suspending
        suspending = Task {
            await previous?.value
            _ = try? await sdk.request(accepting: [.apiESid]) { sdk.localLogout(with: $0) }
        }
    }

    /// Deletes the cache and the decrypted thumbnails of a closed link with no engine: of the
    /// last run, of a stopped engine, or of a file link. `close` deletes those of an engine.
    func removeCache() {
        let caches = [AppPaths.caches.appending(path: "links/\(id.uuidString)"),
                      AppPaths.caches.appending(path: "thumbnails/link-\(id.uuidString)")]
        let suspending = suspending
        Task {
            await suspending?.value
            await EngineQueue.run { caches.forEach(AppPaths.removeAll) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        openingTask?.cancel()
        openingTask = nil
        peekTask?.cancel()
        peekTask = nil
        browser?.stop()
        guard let engine else { return }
        engine.shutdown()
        let sdk = engine.sdk
        let path = AppPaths.linkEngine(id.uuidString)
        let thumbnails = AppPaths.thumbnails(engine.id)
        Task {
            // A fixed delay does not prove the engine has closed its database.
            // Keep the SDK alive and remove the cache only after logout acknowledges.
            guard (try? await sdk.request(accepting: [.apiESid]) { sdk.localLogout(with: $0) }) != nil else { return }
            await EngineQueue.run {
                AppPaths.removeAll(at: path)
                // Decrypted thumbnails and previews of the folder.
                AppPaths.removeAll(at: thumbnails)
            }
        }
    }

}

@Observable
final class LinkCenter {
    /// Open links stay until you close them, also after the app quits or updates.
    private(set) var sessions: [LinkSession] = [] {
        // Links that start the app come before the saved list is read: they must not replace it.
        didSet { if isRestored { save() } }
    }
    @ObservationIgnored private var isRestored = false

    /// The most links that one action opens.
    static let openLimit = 50
    /// The most folder-link engines at the same time: each one keeps files and connections
    /// open. The link selected least recently stops first; it opens again when you select it.
    static let engineLimit = 8
    /// Link IDs, the link selected last at the end.
    @ObservationIgnored private var recent: [UUID] = []
    /// True when a window still uses the engine with this ID (a preview): it does not stop.
    @ObservationIgnored var isInUse: (String) -> Bool = { _ in false }
    /// More links than this from a copy or from another app: the app asks first.
    static let askAbove = 10

    /// The links as you opened them. A password-protected link stays protected: the
    /// password is not stored, and the app asks for it again.
    private static let savedFile = AppPaths.support.appending(path: "open-links.json")

    private struct Saved: Codable {
        let id: UUID
        let link: String
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions.map { Saved(id: $0.id, link: $0.link) }) else { return }
        AppPaths.ensure(AppPaths.support)
        try? data.write(to: Self.savedFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.savedFile.path)
        // The links hold their keys: not in backups. Each write makes a new file.
        var file = Self.savedFile
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
    }

    /// Shows the links of the last run again: file links open, folder links open when you
    /// select them. Links that started the app (they arrive before this) are kept after them.
    func restore(account: MegaEngine, workerThreads: Int) {
        let saved = (try? Data(contentsOf: Self.savedFile)).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        // Engine folders of links that are closed (or of runs before links were kept).
        let folders = AppPaths.caches.appending(path: "links", directoryHint: .isDirectory)
        let kept = Set(saved.map(\.id.uuidString) + sessions.map(\.id.uuidString))
        for folder in (try? FileManager.default.contentsOfDirectory(at: folders, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(folder.lastPathComponent) {
            AppPaths.removeAll(at: folder)
        }
        // Thumbnail folders of the same closed links ("link-<id>"), and of password-protected
        // links: they ask for the password again.
        let locked = Set(saved.filter { LinkParser.isPasswordProtected($0.link) }.map(\.id.uuidString))
        let thumbnails = AppPaths.caches.appending(path: "thumbnails", directoryHint: .isDirectory)
        for folder in (try? FileManager.default.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: nil)) ?? []
        where folder.lastPathComponent.hasPrefix("link-") {
            let id = String(folder.lastPathComponent.dropFirst(5))
            if !kept.contains(id) || locked.contains(id) { AppPaths.removeAll(at: folder) }
        }
        var seen = Set(sessions.map(\.id))
        let open = Set(sessions.map { LinkParser.identity(of: $0.link) })
        let restored = saved.filter { seen.insert($0.id).inserted && !open.contains(LinkParser.identity(of: $0.link)) && !LinkParser.links(in: $0.link).isEmpty }.map { LinkSession(link: $0.link, kind: LinkParser.kind(of: $0.link), id: $0.id) }
        isRestored = true
        sessions = restored + sessions
        for session in restored {
            session.willStartEngine = { [weak self] in self?.makeRoom(for: $0) }
            session.prepare(using: account, workerThreads: workerThreads)
        }
    }

    /// The link shows in the main window.
    func select(_ session: LinkSession) {
        recent.removeAll { $0 == session.id }
        recent.append(session.id)
    }

    /// Before a folder link starts its engine: stops the engines of the links selected least
    /// recently, so that at most `engineLimit` run.
    private func makeRoom(for session: LinkSession) {
        select(session)
        let others = sessions.filter { $0.engine != nil && $0 !== session }
        let busy = Set(others.filter { $0.engine.map { isInUse($0.id) } ?? false }.map(\.id))
        let stopping = Self.enginesToStop(others.map(\.id), busy: busy, recent: recent)
        for other in others where stopping.contains(other.id) { other.suspend() }
    }

    /// The running engines that stop before one more starts: of the links selected least
    /// recently first. An engine that a window uses (`busy`) keeps running, also above the limit.
    static func enginesToStop(_ running: [UUID], busy: Set<UUID>, recent: [UUID]) -> Set<UUID> {
        guard running.count >= engineLimit else { return [] }
        let order = { (id: UUID) in recent.firstIndex(of: id) ?? -1 }
        let idle = running.filter { !busy.contains($0) }.sorted { order($0) < order($1) }
        return Set(idle.prefix(running.count - engineLimit + 1))
    }

    /// Opens every MEGA link found in the text (see `LinkSession.prepare`). Returns the
    /// sessions, also those of links that were open already.
    @discardableResult
    func open(text: String, account: MegaEngine, workerThreads: Int) -> [LinkSession] {
        var opened: [LinkSession] = []
        var added: [LinkSession] = []
        for (link, kind) in LinkParser.links(in: text) {
            let identity = LinkParser.identity(of: link)
            if let existing = sessions.first(where: { LinkParser.identity(of: $0.link) == identity }) {
                opened.append(existing)
                continue
            }
            let session = LinkSession(link: link, kind: kind)
            added.append(session)
            opened.append(session)
        }
        if !added.isEmpty { sessions += added }
        for session in added {
            session.willStartEngine = { [weak self] in self?.makeRoom(for: $0) }
            session.prepare(using: account, workerThreads: workerThreads)
        }
        return opened
    }

    /// The `count` largest of the links (a file, or a folder with all its subfolders);
    /// 0 keeps all. One small request for each link: the folder trees do not load. A link
    /// with no size from MEGA (removed, bad key) comes last. `bySize` is false when MEGA
    /// gave no size at all: then the links keep their order.
    static func largest(_ links: [String], count: Int, sdk: MEGASdk) async -> (links: [String], bySize: Bool) {
        guard count > 0, links.count(where: { !LinkParser.isPasswordProtected($0) }) > count else { return (links, true) }
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?)?.self) { group in
            for link in links {
                group.addTask { (link, await size(of: link, sdk: sdk)) }
            }
            // A link with no answer in time counts as one with no size.
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            var answers = 0
            for await answer in group {
                guard let (link, size) = answer else { break }
                sizes[link] = size
                answers += 1
                if answers == links.count { break }
            }
            group.cancelAll()
        }
        return (pick(links, sizes: sizes, count: count), !sizes.isEmpty)
    }

    /// Largest first; links of the same size keep their order. A password-protected link
    /// has no size before the password: all of them are kept, after the others.
    nonisolated static func pick(_ links: [String], sizes: [String: Int64], count: Int) -> [String] {
        let ranked = links.filter { !LinkParser.isPasswordProtected($0) }.enumerated().sorted { a, b in
            let first = sizes[a.element] ?? -1, second = sizes[b.element] ?? -1
            return first != second ? first > second : a.offset < b.offset
        }
        return ranked.prefix(count).map(\.element) + links.filter(LinkParser.isPasswordProtected)
    }

    private static func size(of link: String, sdk: MEGASdk) async -> Int64? {
        guard !LinkParser.isPasswordProtected(link) else { return nil }
        switch LinkParser.kind(of: link) {
        case .file:
            let request = try? await sdk.request { sdk.publicNode(forMegaFileLink: link, delegate: $0) }
            return request?.publicNode?.size?.int64Value
        case .folder:
            let request = try? await sdk.request { sdk.getPublicLinkInformation(withFolderLink: link, delegate: $0) }
            return request?.megaFolderInfo?.currentSize
        }
    }

    func close(_ session: LinkSession) {
        discard(session)
        sessions.removeAll { $0.id == session.id }
    }

    func closeAll() {
        sessions.forEach(discard)
        sessions.removeAll()
    }

    /// A link that you close. Not at quit: the caches of open links stay for the next run.
    private func discard(_ session: LinkSession) {
        session.close()
        if session.engine == nil { session.removeCache() }
        recent.removeAll { $0 == session.id }
    }

    func session(_ id: UUID) -> LinkSession? {
        sessions.first { $0.id == id }
    }
}

nonisolated enum LinkParser {
    private static let pattern = try! NSRegularExpression(
        // mega:// links have the same paths as web links, and the same boundary before them.
        // Sites can add a query (tracking parameters) between the handle and the key.
        pattern: #"(?<![A-Za-z0-9_./:@-])(?:(?:https?://)?(?:www\.)?mega\.(?:nz|co\.nz|app|io)/|mega://)(?:(?:file|folder)/[A-Za-z0-9_-]+(?:\?[A-Za-z0-9_.~%=&+-]*)?(?:#[A-Za-z0-9_-]+)?(?:/(?:file|folder)/[A-Za-z0-9_-]+)?|#[!FP]*![A-Za-z0-9_!-]+)"#,
        options: [.caseInsensitive])

    static func links(in text: String) -> [(String, LinkSession.Kind)] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var link = String(text[range])
            // The query goes; the key after it stays.
            if let query = link.range(of: #"\?[^#]*"#, options: .regularExpression) { link.removeSubrange(query) }
            if link.lowercased().hasPrefix("mega://") {
                link = "https://mega.nz/" + link.dropFirst("mega://".count)
            } else if !link.lowercased().hasPrefix("http") {
                link = "https://" + link
            }
            guard seen.insert(identity(of: link)).inserted else { return nil }
            return (link, kind(of: link))
        }
    }

    /// The same file or folder in any form of its link: the host, and the old forms
    /// "#F!handle!key" and "#!handle!key", do not count.
    static func identity(of link: String) -> String {
        guard let start = link.range(of: #"(?:file|folder)/|#[!FP]*!"#, options: [.regularExpression, .caseInsensitive]) else { return link }
        let path = link[start.lowerBound...]
        for (old, new) in [("#F!", "folder/"), ("#!", "file/")] where path.hasPrefix(old) {
            let rest = path.dropFirst(old.count)
            guard let bang = rest.firstIndex(of: "!") else { return new + rest }
            return new + rest[..<bang] + "#" + rest[rest.index(after: bang)...]
        }
        return String(path)
    }

    static func kind(of link: String) -> LinkSession.Kind {
        let lower = link.lowercased()
        return lower.contains("/folder/") || lower.contains("#f!") ? .folder : .file
    }

    static func isPasswordProtected(_ link: String) -> Bool {
        link.contains("#P!")
    }
}
