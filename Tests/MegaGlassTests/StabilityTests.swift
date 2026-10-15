import Foundation
import CoreGraphics
import ImageIO
import Observation
import Testing
@preconcurrency import MEGASdk
@testable import MegaGlass

@MainActor
private func makeEngine(kind: MegaEngine.Kind = .folderLink) throws -> (MegaEngine, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "megaglass-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let engine = MegaEngine(kind: kind, id: UUID().uuidString, basePath: root,
                            workerThreads: 1, thumbnailDirectory: root.appending(path: "thumbnails"))
    return (engine, root)
}

@MainActor
private func eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

struct CallbackGateTests {
    @Test func completionBeforeInstallationAndDuplicates() async throws {
        let gate = AsyncResultGate<Int>()
        gate.finish(.success(7))
        gate.finish(.success(8))
        let value = try await withCheckedThrowingContinuation { gate.install($0) }
        #expect(value == 7)
    }

    @Test func cancellationBeforeInstallation() async {
        let gate = AsyncResultGate<Int>()
        gate.cancel()
        gate.finish(.success(8))
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { gate.install($0) }
        }
    }

    @Test func logoutDeadlineCancelsUnfinishedWaiter() async {
        await #expect(throws: RequestDeadline.Timeout.self) {
            try await RequestDeadline.run(for: .milliseconds(5)) {
                try await Task.sleep(for: .seconds(60))
            }
        }
    }

    @Test func deadlinePreservesSuccessfulResult() async throws {
        let value = try await RequestDeadline.run(for: .seconds(10)) { 42 }
        #expect(value == 42)
    }

    @Test func simultaneousFinishAndCancel() async {
        for _ in 0..<100 {
            let gate = AsyncResultGate<Int>()
            let waiter = Task { try await withCheckedThrowingContinuation { gate.install($0) } }
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask {
                        if index.isMultiple(of: 2) { gate.cancel() }
                        else { gate.finish(.success(index)) }
                    }
                }
            }
            let result = await waiter.result
            if case let .success(value) = result { #expect((0..<20).contains(value)) }
            else if case let .failure(error) = result { #expect(error is CancellationError) }
        }
    }
}

@MainActor
private final class MockAuthentication: SessionAuthentication {
    var email: String? = "tester@example.invalid"
    var loginCount = 0
    var restoreCount = 0
    var logoutCount = 0
    var localLogoutCount = 0
    var loginFailure: MegaFailure?
    var restoreFailure: MegaFailure?
    var fetchFailure: MegaFailure?
    var logoutFailure: MegaFailure?
    var localLogoutFailure: MegaFailure?
    var loginGate: AsyncResultGate<Void>?
    var fetchGate: AsyncResultGate<Void>?
    var progress: (@Sendable (Int64, Int64) -> Void)?
    func restore(_ token: String) async throws {
        restoreCount += 1
        if let restoreFailure { throw restoreFailure }
    }
    func login(email: String, password: String, code: String?) async throws {
        loginCount += 1
        if let loginGate { try await withCheckedThrowingContinuation { loginGate.install($0) } }
        if let loginFailure { throw loginFailure }
    }
    func fetchNodes(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        self.progress = progress
        progress(20, 100)
        if let fetchGate { try await withCheckedThrowingContinuation { fetchGate.install($0) } }
        if let fetchFailure { throw fetchFailure }
    }
    func logout() async throws {
        logoutCount += 1
        if let logoutFailure { throw logoutFailure }
    }
    func localLogout() async throws {
        localLogoutCount += 1
        if let localLogoutFailure { throw localLogoutFailure }
    }
    func dumpSession() -> String? { "isolated-fixture-token" }
}

@MainActor
private final class MemoryCredentials: SessionCredentials {
    var token: String?
    var saves = 0
    var deletes = 0
    var failure: MegaFailure?
    func read() -> String? { token }
    func save(_ token: String) throws {
        if let failure { throw failure }
        saves += 1
        self.token = token
    }
    func delete() throws {
        if let failure { throw failure }
        deletes += 1
        token = nil
    }
}

@MainActor
struct AuthenticationTests {
    @Test func loginLogoutAndLateProgress() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        #expect(session.phase == .signedOut)
        for _ in 0..<3 {
            try await session.signIn(email: " tester@example.invalid ", password: "fixture", code: nil)
            #expect(session.isSignedIn)
            #expect(credentials.token != nil)
            auth.progress?(99, 100)
            await Task.yield()
            #expect(session.isSignedIn) // A queued progress event cannot replace ready.
            await session.signOut()
            auth.progress?(100, 100)
            await Task.yield()
            #expect(session.phase == .signedOut)
            #expect(session.email == nil)
            #expect(credentials.token == nil)
        }
        #expect(auth.loginCount == 3)
        #expect(auth.logoutCount == 3)
    }

    @Test(arguments: [-9, -26, -3]) func rejectedLogin(code: Int) async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        auth.loginFailure = MegaFailure(code: code, message: "Fixture failure")
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        await #expect(throws: MegaFailure.self) {
            try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        }
        #expect(session.phase == .signedOut)
        #expect(credentials.saves == 0)
    }

    @Test(arguments: [-15, -9, -16, -3]) func restoreFailureRetainsOnlyRetryableSession(code: Int) async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        credentials.token = "fixture"
        auth.restoreFailure = MegaFailure(code: code, message: "Fixture restore failure")
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        #expect(session.phase == .signedOut)
        #expect((credentials.token != nil) == (code == -3))
        #expect(session.startupMessage != nil)
    }

    @Test func successfulRestoreOnlyRunsOnce() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        credentials.token = "fixture"
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        await session.start()
        #expect(session.isSignedIn)
        #expect(auth.restoreCount == 1)
    }

    @Test func duplicateLoginIsRejectedAcrossWindows() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let gate = AsyncResultGate<Void>()
        auth.loginGate = gate
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        let login = Task { try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil) }
        #expect(await eventually { auth.loginCount == 1 })
        await #expect(throws: MegaFailure.self) {
            try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        }
        gate.finish(.success(()))
        try await login.value
        #expect(auth.loginCount == 1)
        await session.signOut()
    }

    @Test func closingLoginWindowDoesNotStrandSDKSession() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let gate = AsyncResultGate<Void>()
        auth.loginGate = gate
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        let login = Task { try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil) }
        #expect(await eventually { auth.loginCount == 1 })
        login.cancel()
        gate.finish(.success(()))
        try await login.value
        #expect(session.isSignedIn)
        await session.signOut()
    }

    @Test func fetchFailureResetsSDKForRetry() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        auth.fetchFailure = MegaFailure(code: -3, message: "Offline")
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        await #expect(throws: MegaFailure.self) {
            try await session.signIn(email: "tester@example.invalid", password: "fixture", code: "123456")
        }
        #expect(auth.localLogoutCount == 1)
        #expect(session.phase == .signedOut)
        auth.fetchFailure = nil
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        #expect(session.isSignedIn)
        await session.signOut()
    }

    @Test func offlineLogoutFallsBackLocally() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        auth.logoutFailure = MegaFailure(code: -3, message: "Offline")
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        await session.signOut()
        #expect(auth.localLogoutCount == 1)
        #expect(session.phase == .signedOut)
        #expect(credentials.token == nil)
    }

    @Test func logoutDuringReloadRejectsStaleCompletion() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        let gate = AsyncResultGate<Void>()
        auth.fetchGate = gate
        engine.onReloadNeeded?()
        #expect(await eventually { if case .loadingAccount = session.phase { return true }; return false })
        await session.signOut()
        gate.finish(.success(()))
        await Task.yield()
        await Task.yield()
        #expect(session.phase == .signedOut)
        #expect(session.email == nil)
    }

    @Test func sessionGenerationNotifiesPreviewObservers() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        let changed = AsyncResultGate<Void>()
        withObservationTracking { _ = session.generation } onChange: { changed.finish(.success(())) }
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        #expect(changed.isFinished)
        await session.signOut()
    }

    @Test func invalidSessionEventReturnsToLogin() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        engine.onSessionExpired?()
        #expect(await eventually { session.phase == .signedOut })
        #expect(credentials.token == nil)
        #expect(session.startupMessage != nil)
    }

    @Test func keychainFailureIsReportedWithoutDiscardingLogin() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        credentials.failure = MegaFailure(code: -1, message: "Fixture keychain failure")
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        var reports = 0
        session.onError = { _ in reports += 1 }
        await session.start()
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        #expect(session.isSignedIn)
        #expect(reports == 1)
    }
}

private actor ControlledListings {
    var calls: Set<Location> = []
    private var gates: [Location: AsyncResultGate<Listing>] = [:]
    func list(_ location: Location) async -> Listing {
        calls.insert(location)
        let gate = gates[location] ?? AsyncResultGate<Listing>()
        gates[location] = gate
        return (try? await withCheckedThrowingContinuation { gate.install($0) }) ?? Listing()
    }
    func finish(_ location: Location, _ listing: Listing) {
        let gate = gates[location] ?? AsyncResultGate<Listing>()
        gates[location] = gate
        gate.finish(.success(listing))
    }
    func hasCalled(_ location: Location) -> Bool { calls.contains(location) }
}

@MainActor
struct BrowserTests {
    @Test func rapidNavigationRejectsLateListing() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let source = ControlledListings()
        let model = BrowserModel(engine: engine, start: .folder(1), listingProvider: { location, _, _ in
            await source.list(location)
        })
        #expect(await eventually { await source.hasCalled(.folder(1)) })
        model.go(to: .folder(2))
        #expect(!model.canWrite)
        #expect(model.selection.isEmpty)
        await source.finish(.folder(2), Listing(items: [NodeItem(id: 2, name: "New")]))
        #expect(await eventually { model.items.first?.id == 2 })
        await source.finish(.folder(1), Listing(items: [NodeItem(id: 1, name: "Stale")], canWrite: true))
        await Task.yield()
        #expect(model.items.map(\.id) == [2])
        #expect(!model.canWrite)
        #expect(model.canGoBack)
        model.stop()
    }

    @Test func searchCannotBeOverwrittenByFolderLoad() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let source = ControlledListings()
        let model = BrowserModel(engine: engine, start: .folder(1), listingProvider: { location, _, _ in
            await source.list(location)
        }, searchProvider: { _ in [NodeItem(id: 8, name: "Found")] })
        #expect(await eventually { await source.hasCalled(.folder(1)) })
        model.searchText = "Found"
        #expect(await eventually { model.items.first?.id == 8 })
        await source.finish(.folder(1), Listing(items: [NodeItem(id: 1, name: "Stale")]))
        await Task.yield()
        #expect(model.isSearching)
        #expect(model.items.map(\.id) == [8])
        model.stop()
    }

    @Test func failedListingIsVisibleAndEmptyListingClearsSelection() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(engine: engine, start: .favourites, listingProvider: { _, _, _ in
            Listing(errorMessage: "Offline")
        })
        #expect(await eventually { model.errorMessage == "Offline" })
        #expect(!model.isLoading)
        model.stop()
        let empty = BrowserModel(engine: engine, start: .folder(1), listingProvider: { _, _, _ in Listing() })
        empty.selection = [99]
        #expect(await eventually { !empty.isLoading })
        #expect(empty.selection.isEmpty)
        empty.stop()
    }

    @Test func largeFolderSortIsStrictAndDeterministic() {
        let items = (0..<10_000).map { NodeItem(id: UInt64($0), name: "Same", size: Int64($0 % 3)) }
        for key in SortKey.allCases {
            let sorted = BrowserModel.sort(items.reversed(), by: key, ascending: false)
            #expect(sorted.count == items.count)
            #expect(Set(sorted.map(\.id)).count == items.count)
            #expect(BrowserModel.sort(sorted, by: key, ascending: false) == sorted)
            let pair = [NodeItem(id: 1, name: "A"), NodeItem(id: 2, name: "B")]
            #expect(BrowserModel.sort(pair, by: .name, ascending: false).map(\.id) == [2, 1])
        }
        let folder = NodeItem(id: 11, name: "Z", isFolder: true)
        #expect(BrowserModel.sort([items[0], folder], by: .name, ascending: false).first == folder)
    }
}

@MainActor
struct TransferTests {
    @Test func terminalStateRejectsLateAndRepeatedCallbacks() {
        let item = TransferItem(TransferSnapshot(tag: 1, errorMessage: "Retrying"))
        item.update(TransferSnapshot(tag: 1, transferredBytes: 50))
        #expect(item.errorMessage == nil)
        item.update(TransferSnapshot(tag: 1, transferredBytes: 100, state: .complete, finished: true))
        let date = item.finishedAt
        item.update(TransferSnapshot(tag: 1, transferredBytes: 20))
        item.update(TransferSnapshot(tag: 1, state: .failed, errorMessage: "Late failure", finished: true))
        #expect(item.state == .complete)
        #expect(item.transferredBytes == 100)
        #expect(item.finishedAt == date)
        #expect(item.statusText == "Downloaded")
    }

    @Test(arguments: [MEGATransferState.failed, .cancelled]) func failuresNeverAppearComplete(state: MEGATransferState) {
        let item = TransferItem(TransferSnapshot(tag: 1, state: state, errorMessage: "Fixture failure", finished: true))
        #expect(item.isFinished)
        #expect(item.state != .complete)
        #expect(item.statusText != "Downloaded")
    }

    @Test func multiTransferProgressDoesNotOverflowAndResetIsComplete() throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let center = TransferCenter(engine: engine)
        var finishes = 0
        center.onFinished = { _ in finishes += 1 }
        center.apply([
            TransferSnapshot(tag: 1, totalBytes: .max, transferredBytes: .max / 2),
            TransferSnapshot(tag: 2, isDownload: false, totalBytes: .max, transferredBytes: .max / 2),
        ])
        #expect(abs(center.overallProgress - 0.5) < 0.001)
        center.apply([TransferSnapshot(tag: 1, state: .failed, errorMessage: "Offline", finished: true)])
        center.apply([TransferSnapshot(tag: 1, state: .complete, finished: true)])
        #expect(finishes == 1)
        #expect(center.items.first?.state == .failed)
        center.reset()
        #expect(center.items.isEmpty)
        #expect(center.activeCount == 0)
        #expect(center.overallProgress == 0)
        center.shutdown()
    }

    @Test func clearedTransfersCannotBeResurrectedByQueuedProgress() {
        let feed = TransferFeed()
        feed.enqueue(TransferSnapshot(tag: 5, state: .complete, finished: true))
        feed.enqueue(TransferSnapshot(tag: 5, transferredBytes: 10))
        #expect(feed.drain().first?.finished == true)
        feed.forget(5)
        feed.enqueue(TransferSnapshot(tag: 5, transferredBytes: 10))
        #expect(feed.drain().isEmpty)
    }

    @Test func speedLimitsAreClampedWithoutOverflow() {
        #expect(TransferCenter.bytesPerSecond(-1) == 0)
        #expect(TransferCenter.bytesPerSecond(5) == 5120)
        #expect(TransferCenter.bytesPerSecond(Int.max) > 0)
    }
}

@MainActor
struct PlatformTests {
    @Test(arguments: ["../outside", "/absolute", "..", ".", "", "a/b:c\0.txt", "日本語 😀.txt"])
    func remoteNamesRemainInsideDestination(name: String) {
        let safe = LocalFileSafety.filename(name)
        let root = URL(filePath: "/tmp/isolated")
        let url = root.appendingPathComponent(safe).standardizedFileURL
        #expect(url.deletingLastPathComponent().path == root.path)
        #expect(!safe.contains("/"))
        #expect(!safe.contains("\0"))
        if name == "日本語 😀.txt" { #expect(safe == name) }
    }

    @Test func invalidAndReadOnlyDownloadDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        try LocalFileSafety.validateDownloadDirectory(root)
        #expect(throws: (any Error).self) { try LocalFileSafety.validateDownloadDirectory(URL(string: "https://example.invalid")!) }
        #expect(throws: (any Error).self) { try LocalFileSafety.validateDownloadDirectory(root.appending(path: "missing")) }
        let file = root.appending(path: "file")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try LocalFileSafety.validateDownloadDirectory(file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try LocalFileSafety.validateDownloadDirectory(root) }
    }

    @Test func deniedKeychainWritesCannotRestoreAnOldAccount() throws {
        let suite = "megaglass-credential-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MemoryCredentials()
        backend.token = "old-fixture"
        func makeStore() -> KeychainSessionCredentials {
            KeychainSessionCredentials(defaults: defaults, load: { backend.read() },
                                       save: { try backend.save($0) }, remove: { try backend.delete() })
        }
        let store = makeStore()
        #expect(try store.read() == "old-fixture")
        backend.failure = MegaFailure(code: -1, message: "Fixture Keychain denied")
        #expect(throws: MegaFailure.self) { try store.save("new-fixture") }
        #expect(backend.token == "old-fixture") // Failed replacement does not destroy it.
        #expect(try makeStore().read() == nil) // But an old account cannot auto-restore.
        backend.failure = nil
        try store.save("new-fixture")
        #expect(try makeStore().read() == "new-fixture")
        backend.failure = MegaFailure(code: -1, message: "Fixture Keychain denied")
        #expect(throws: MegaFailure.self) { try store.delete() }
        #expect(try makeStore().read() == nil)
    }

    @Test func corruptPreferencesAreBounded() throws {
        let suite = "megaglass-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-100, forKey: "workerThreads")
        defaults.set(Int.max, forKey: "downloadConnections")
        defaults.set(-1, forKey: "uploadConnections")
        defaults.set(-1, forKey: "uploadLimitKB")
        defaults.set(Double.infinity, forKey: "gridSize")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.workerThreads == 1)
        #expect(settings.downloadConnections == 32)
        #expect(settings.uploadConnections == 1)
        #expect(settings.uploadLimitKB == 0)
        #expect(settings.gridSize.isFinite)
    }

    @Test func passwordProtectionNeverFallsBackToPlaintext() {
        let plain = "https://mega.nz/file/fixture#fixtureKey"
        #expect(LinkPresentation.lines(links: [plain], protected: [], usePassword: true, separateKey: false).isEmpty)
        #expect(LinkPresentation.lines(links: [plain], protected: ["protected-fixture"], usePassword: true, separateKey: true) == ["protected-fixture"])
        #expect(LinkPresentation.lines(links: [plain], protected: [], usePassword: false, separateKey: true) == ["https://mega.nz/file/fixture", "Key: fixtureKey"])
    }

    @Test func invalidMediaTimesNeverTrap() {
        #expect(Format.playtime(.infinity) == "–")
        #expect(Format.playtime(.nan) == "–")
        #expect(Format.playtime(.greatestFiniteMagnitude) == "–")
        #expect(Format.playtime(Double(Int.max)) == "–")
    }

    @Test func browserRouterRejectsSelfAndInvalidBundles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".app")
        let contents = root.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.megaglass.MegaGlass"], format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        #expect(!BrowserRouter.isForwardTarget(root))
        #expect(!BrowserRouter.isForwardTarget(URL(filePath: "/tmp/not-a-browser")))
    }

    @Test func parserRejectsHostSubstringsAndDeduplicates() {
        #expect(LinkParser.links(in: "https://evilmega.nz/file/abc#key").isEmpty)
        #expect(LinkParser.links(in: "https://evil.invalid/mega.nz/file/abc#key").isEmpty)
        #expect(LinkParser.links(in: "https://mega.nz/file/abc#key https://mega.nz/file/abc#key").count == 1)
        #expect(LinkParser.links(in: "mega://folder/abc#key").count == 1)
        #expect(LinkParser.isPasswordProtected("https://mega.nz/#P!encrypted"))
        #expect(!LinkSorter.isMega("mega.nz.evil.invalid"))
    }

    @Test func closingUnopenedLinkPreventsSDKWork() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let link = LinkSession(link: "https://mega.nz/folder/fixture#key", kind: .folder)
        link.close()
        await link.open(using: engine, workerThreads: 1)
        #expect(link.engine == nil)
        #expect(link.browser == nil)
    }
}

nonisolated private final class FixtureMegaError: MEGAError, @unchecked Sendable {
    let fixtureType: MEGAErrorType
    init(_ type: MEGAErrorType) { fixtureType = type; super.init() }
    override var type: MEGAErrorType { fixtureType }
    override var name: String { "Isolated fixture error" }
}

@MainActor
struct SDKRequestBoundaryTests {
    @Test func engineShutdownReleasesSDKAndListeners() throws {
        for _ in 0..<3 {
            weak var engineReference: MegaEngine?
            weak var sdkReference: MEGASdk?
            try autoreleasepool {
                let (engine, root) = try makeEngine(kind: .account)
                engineReference = engine
                sdkReference = engine.sdk
                engine.resetEvents()
                engine.shutdown()
                engine.shutdown()
                try? FileManager.default.removeItem(at: root)
            }
            #expect(engineReference == nil)
            #expect(sdkReference == nil)
        }
    }

    @Test func successAndAcceptedErrorUseActualRequestAdapter() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sdk = engine.sdk
        for code in [MEGAErrorType.apiOk, .apiENoent] {
            let result = try await sdk.request(accepting: [.apiENoent]) { delegate in
                delegate.onRequestFinish?(sdk, request: MEGARequest(), error: FixtureMegaError(code))
                delegate.onRequestFinish?(sdk, request: MEGARequest(), error: FixtureMegaError(.apiEFailed))
            }
            #expect(result.nodeHandle == invalidHandle)
        }
    }

    @Test func failedRequestPropagatesSDKError() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sdk = engine.sdk
        await #expect(throws: MegaFailure.self) {
            _ = try await sdk.request { delegate in
                delegate.onRequestFinish?(sdk, request: MEGARequest(), error: FixtureMegaError(.apiEAccess))
            }
        }
    }

    @Test func cancelledRequestReturnsWithoutCallbackAndIgnoresLateFinish() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sdk = engine.sdk
        var delegate: (any MEGARequestDelegate)?
        let task = Task { try await sdk.request {
            MainActor.assertIsolated()
            delegate = $0
        } }
        #expect(await eventually { delegate != nil })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        delegate?.onRequestFinish?(sdk, request: MEGARequest(), error: FixtureMegaError(.apiOk))
        delegate?.onRequestFinish?(sdk, request: MEGARequest(), error: FixtureMegaError(.apiEFailed))
        delegate = nil
    }

    @Test func isolatedPreviewDestinationsAndPrestartCancellation() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let first = PreviewDownload(root: root), second = PreviewDownload(root: root)
        #expect(first.directory != second.directory)
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.run(sdk: engine.sdk, node: MEGANode()) { _ in }
        }
    }
}


nonisolated private func pixelPNG() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private actor AttributeWriter {
    let image: Data
    let gate: AsyncResultGate<Void>?
    var paths: [URL] = []
    var failuresRemaining: Int
    init(image: Data, gate: AsyncResultGate<Void>? = nil, failures: Int = 0) {
        self.image = image
        self.gate = gate
        failuresRemaining = failures
    }
    func write(_ url: URL) async throws {
        paths.append(url)
        try Data("partial fixture".utf8).write(to: url)
        if let gate { try await withCheckedThrowingContinuation { gate.install($0) } }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MegaFailure(code: -3, message: "Interrupted fixture")
        }
        try image.write(to: url)
    }
    var count: Int { paths.count }
}

@MainActor
struct ThumbnailTests {
    @Test func clearingCacheDuringAttributeWriteRejectsLateImage() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let gate = AsyncResultGate<Void>()
        let writer = AttributeWriter(image: try pixelPNG(), gate: gate)
        let store = ThumbnailStore(sdk: engine.sdk, directory: root.appending(path: "isolated-cache"),
                                   fetchAttribute: { _, _, _, url in try await writer.write(url) })
        let read = Task { await store.thumbnail(42) }
        #expect(await eventually { await writer.count == 1 })
        let path = try #require(await writer.paths.first)
        #expect(FileManager.default.fileExists(atPath: path.path))
        store.clear()
        // Clearing cannot remove a directory while the SDK still owns a writer.
        #expect(FileManager.default.fileExists(atPath: path.path))
        gate.finish(.success(()))
        #expect(await read.value == nil)
        #expect(store.cached(42) == nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path) })
    }

    @Test func interruptedAttributeDoesNotPoisonRetry() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let writer = AttributeWriter(image: try pixelPNG(), failures: 1)
        let store = ThumbnailStore(sdk: engine.sdk, directory: root.appending(path: "isolated-cache"),
                                   fetchAttribute: { _, _, _, url in try await writer.write(url) })
        #expect(await store.thumbnail(42) == nil)
        #expect(await store.thumbnail(42) != nil)
        #expect(await writer.count == 2)
        #expect(store.cached(42) != nil)
        for path in await writer.paths { #expect(!FileManager.default.fileExists(atPath: path.path)) }
    }

    @Test func committedDiskCacheSurvivesStoreRecreation() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let writer = AttributeWriter(image: try pixelPNG())
        let cache = root.appending(path: "isolated-cache")
        var store: ThumbnailStore? = ThumbnailStore(sdk: engine.sdk, directory: cache,
            fetchAttribute: { _, _, _, url in try await writer.write(url) })
        #expect(await store?.thumbnail(42) != nil)
        store = nil
        let restored = ThumbnailStore(sdk: engine.sdk, directory: cache,
            fetchAttribute: { _, _, _, url in try await writer.write(url) })
        #expect(await restored.thumbnail(42) != nil)
        #expect(await writer.count == 1)
    }
}
