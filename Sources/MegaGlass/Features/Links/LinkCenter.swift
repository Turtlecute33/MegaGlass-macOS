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
        case opening
        case needsPassword
        case ready
        case failed(String)
    }

    /// Stays the same after a restart: the engine folder and preview windows use it.
    let id: UUID
    let link: String
    private(set) var kind: Kind
    private(set) var state: State = .opening
    private(set) var title: String
    /// For file links.
    private(set) var fileNode: MEGANode?
    private(set) var fileItem: NodeItem?
    /// For folder links.
    private(set) var engine: MegaEngine?
    private(set) var browser: BrowserModel?

    @ObservationIgnored private var closed = false
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private var resolvedLink: String

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

    func beginOpen(using account: MegaEngine, workerThreads: Int) {
        guard !closed, openingTask == nil else { return }
        openingTask = Task {
            defer { openingTask = nil }
            await open(using: account, workerThreads: workerThreads)
        }
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
                title = node.name ?? title
            case .folder:
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
                title = root.name ?? title
                // Open links show the largest items first.
                browser = BrowserModel(engine: engine, start: .folder(root.handle), rootTitle: title,
                                       sortKey: .size, ascending: false)
            }
            state = .ready
        } catch {
            guard !closed, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func unlock(password: String, using account: MegaEngine, workerThreads: Int) async {
        guard !closed, openingTask == nil else { return }
        let task = Task {
            defer { openingTask = nil }
            await unlockLink(password: password, using: account, workerThreads: workerThreads)
        }
        openingTask = task
        await task.value
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

    func close() {
        guard !closed else { return }
        closed = true
        openingTask?.cancel()
        openingTask = nil
        browser?.stop()
        guard let engine else { return }
        engine.shutdown()
        let sdk = engine.sdk
        let path = AppPaths.linkEngine(id.uuidString)
        Task {
            // A fixed delay does not prove the engine has closed its database.
            // Keep the SDK alive and remove the cache only after logout acknowledges.
            guard (try? await sdk.request(accepting: [.apiESid]) { sdk.localLogout(with: $0) }) != nil else { return }
            await EngineQueue.run { AppPaths.removeAll(at: path) }
        }
    }

}

@Observable
final class LinkCenter {
    /// Open links stay until you close them, also after the app quits or updates.
    private(set) var sessions: [LinkSession] = [] {
        didSet { save() }
    }

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
    }

    /// Opens the links of the last run again, all at the same time.
    func restore(account: MegaEngine, workerThreads: Int) {
        guard sessions.isEmpty else { return }
        let saved = (try? Data(contentsOf: Self.savedFile)).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        // Engine folders of links that are closed (or of runs before links were kept).
        let folders = AppPaths.caches.appending(path: "links", directoryHint: .isDirectory)
        let kept = Set(saved.map(\.id.uuidString))
        for folder in (try? FileManager.default.contentsOfDirectory(at: folders, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(folder.lastPathComponent) {
            AppPaths.removeAll(at: folder)
        }
        var seen = Set<UUID>()
        let restored = saved.filter { seen.insert($0.id).inserted && !LinkParser.links(in: $0.link).isEmpty }.map { LinkSession(link: $0.link, kind: LinkParser.kind(of: $0.link), id: $0.id) }
        sessions = restored
        for session in restored {
            session.beginOpen(using: account, workerThreads: workerThreads)
        }
    }

    /// Opens every MEGA link found in the text. Returns the new sessions.
    @discardableResult
    func open(text: String, account: MegaEngine, workerThreads: Int) -> [LinkSession] {
        let found = LinkParser.links(in: text)
        var opened: [LinkSession] = []
        for (link, kind) in found {
            if let existing = sessions.first(where: { $0.link == link }) {
                opened.append(existing)
                continue
            }
            let session = LinkSession(link: link, kind: kind)
            sessions.append(session)
            opened.append(session)
            session.beginOpen(using: account, workerThreads: workerThreads)
        }
        return opened
    }

    func close(_ session: LinkSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
    }

    func closeAll() {
        sessions.forEach { $0.close() }
        sessions.removeAll()
    }

    func session(_ id: UUID) -> LinkSession? {
        sessions.first { $0.id == id }
    }
}

nonisolated enum LinkParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_./:@-])(?:https?://)?(?:www\.)?mega\.(?:nz|co\.nz|app|io)/(?:(?:file|folder)/[A-Za-z0-9_-]+(?:#[A-Za-z0-9_-]+)?(?:/(?:file|folder)/[A-Za-z0-9_-]+)?|#[!FP]*![A-Za-z0-9_!-]+)|mega://[^\s]+"#,
        options: [.caseInsensitive])

    static func links(in text: String) -> [(String, LinkSession.Kind)] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var link = String(text[range])
            if link.lowercased().hasPrefix("mega://") {
                link = "https://mega.nz/" + link.dropFirst("mega://".count)
            } else if !link.lowercased().hasPrefix("http") {
                link = "https://" + link
            }
            guard seen.insert(link).inserted else { return nil }
            return (link, kind(of: link))
        }
    }

    static func kind(of link: String) -> LinkSession.Kind {
        let lower = link.lowercased()
        return lower.contains("/folder/") || lower.contains("#f!") ? .folder : .file
    }

    static func isPasswordProtected(_ link: String) -> Bool {
        link.contains("#P!")
    }
}
