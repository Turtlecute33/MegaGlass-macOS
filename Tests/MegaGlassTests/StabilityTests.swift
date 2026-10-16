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
        engine.onSessionExpired?(nil)
        #expect(await eventually { session.phase == .signedOut })
        #expect(credentials.token == nil)
        #expect(session.startupMessage == "Your session has expired. Log in again.")
        // MEGA already ended the session: the logout happens on this Mac only.
        #expect(auth.logoutCount == 0)
        #expect(auth.localLogoutCount == 1)
    }

    @Test func blockedAccountShowsTheReasonAndDeletesLocalCache() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "account-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: cache.appending(path: "statecache.db"))
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let session = Session(engine: engine, authentication: auth, credentials: credentials, localCache: cache)
        await session.start()
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        engine.onSessionExpired?("Fixture block reason")
        #expect(await eventually { session.phase == .signedOut })
        #expect(session.startupMessage == "Fixture block reason")
        #expect(credentials.token == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    @Test func failedAccountLoadIsShownAndNotRemembered() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        auth.fetchFailure = MegaFailure(code: -3, message: "Fixture offline")
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        await #expect(throws: MegaFailure.self) {
            try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        }
        // The login screen that started the login is gone: the reason stays on the session.
        #expect(session.startupMessage == "Fixture offline")
        // A login that did not load the account does not restore at the next launch.
        #expect(credentials.saves == 0)
        #expect(credentials.token == nil)
    }

    @Test func cancelDuringRestoreKeepsSavedSession() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        credentials.token = "fixture"
        let gate = AsyncResultGate<Void>()
        auth.fetchGate = gate
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        let start = Task { await session.start() }
        #expect(await eventually { if case .loadingAccount = session.phase { return true }; return false })
        await session.cancelLoading()
        #expect(session.phase == .signedOut)
        #expect(auth.localLogoutCount >= 1)
        // The late answer of the stopped load changes nothing.
        gate.finish(.success(()))
        await start.value
        #expect(session.phase == .signedOut)
        #expect(credentials.token == "fixture")
        #expect(credentials.deletes == 0)
        #expect(session.startupMessage == nil)
    }

    @Test func cancelDuringSignInAllowsNewLogin() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        let gate = AsyncResultGate<Void>()
        auth.fetchGate = gate
        let session = Session(engine: engine, authentication: auth, credentials: credentials)
        await session.start()
        let login = Task { try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil) }
        #expect(await eventually { if case .loadingAccount = session.phase { return true }; return false })
        await session.cancelLoading()
        #expect(session.phase == .signedOut)
        gate.finish(.success(()))
        await #expect(throws: (any Error).self) { try await login.value }
        #expect(credentials.saves == 0)
        auth.fetchGate = nil
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        #expect(session.isSignedIn)
        #expect(credentials.saves == 1)
        await session.signOut()
    }

    @Test func offlineLogoutDeletesLocalCacheAndExplains() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "account-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: cache.appending(path: "statecache.db"))
        let auth = MockAuthentication(), credentials = MemoryCredentials()
        auth.logoutFailure = MegaFailure(code: -3, message: "Offline")
        let session = Session(engine: engine, authentication: auth, credentials: credentials, localCache: cache)
        await session.start()
        try await session.signIn(email: "tester@example.invalid", password: "fixture", code: nil)
        await session.signOut()
        #expect(session.phase == .signedOut)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        #expect(session.startupMessage?.contains("server") == true)
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

private actor ListingCounter {
    var count = 0
    func next() -> Listing {
        count += 1
        return Listing(items: [NodeItem(id: 1, name: "Fixture")])
    }
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

    @Test func mergedEngineChangesReloadTheVisibleFolder() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let counter = ListingCounter()
        let model = BrowserModel(engine: engine, start: .folder(1), listingProvider: { _, _, _ in
            await counter.next()
        })
        #expect(await eventually { await counter.count == 1 && !model.isLoading })
        // The next change, for another folder: nothing to reload.
        model.handle(NodeChange(serial: 1, parents: [99], handles: [100]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await counter.count == 1)
        // A gap: the change for this folder (serial 2) was merged into serial 3.
        model.handle(NodeChange(serial: 3, parents: [99], handles: [101]))
        #expect(await eventually { await counter.count == 2 })
        model.stop()
    }

    @Test func rubbishBinIsNotAnUploadTarget() async throws {
        let (engine, root) = try makeEngine(kind: .account)
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let rubbish = BrowserModel(engine: engine, start: .folder(1), listingProvider: { _, _, _ in
            Listing(canWrite: true, isRubbish: true)
        })
        #expect(await eventually { !rubbish.isLoading && rubbish.canWrite })
        #expect(!rubbish.canUpload)
        rubbish.stop()
        let folder = BrowserModel(engine: engine, start: .folder(2), listingProvider: { _, _, _ in
            Listing(canWrite: true)
        })
        #expect(await eventually { !folder.isLoading && folder.canWrite })
        #expect(folder.canUpload)
        folder.stop()
    }

    @Test func readWriteAccessCanUploadButNotModify() async throws {
        var listing = Listing()
        listing.setAccess(.accessRead)
        #expect(!listing.canWrite && !listing.canModify)
        listing.setAccess(.accessReadWrite)
        #expect(listing.canWrite && !listing.canModify)
        listing.setAccess(.accessFull)
        #expect(listing.canWrite && listing.canModify)
        listing.setAccess(.accessOwner)
        #expect(listing.canWrite && listing.canModify)

        let (engine, root) = try makeEngine(kind: .account)
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        var shared = Listing()
        shared.setAccess(.accessReadWrite)
        let share = BrowserModel(engine: engine, start: .folder(3), listingProvider: { [shared] _, _, _ in shared })
        #expect(await eventually { !share.isLoading && share.canWrite })
        #expect(share.canUpload)
        #expect(!share.canModify)
        share.stop()
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

    @Test func bypassResultKeepsTheLargestLinks() {
        let links = ["a", "b", "c", "d", "e"]
        let sizes: [String: Int64] = ["a": 5, "b": 100, "c": 5, "e": 40]
        #expect(LinkCenter.pick(links, sizes: sizes, count: 2) == ["b", "e"])
        // Same size: the first link wins. No size (d): last.
        #expect(LinkCenter.pick(links, sizes: sizes, count: 4) == ["b", "e", "a", "c"])
        #expect(LinkCenter.pick(links, sizes: [:], count: 2) == ["a", "b"])
        // A password-protected link has no size before the password: it is always kept.
        let locked = "https://mega.nz/#P!fixture"
        #expect(LinkCenter.pick(["a", locked, "b", "c"], sizes: ["a": 1, "b": 3, "c": 2], count: 2) == ["b", "c", locked])
    }

    @Test func queryBeforeTheKeyKeepsTheKey() {
        #expect(LinkParser.links(in: "https://mega.nz/file/AbCdEfGh?fbclid=IwAR0_x-Y#key123").map(\.0) == ["https://mega.nz/file/AbCdEfGh#key123"])
        #expect(LinkParser.links(in: "mega.nz/folder/AbCd?utm_source=x&utm_medium=y#Key/file/Sub").map(\.0) == ["https://mega.nz/folder/AbCd#Key/file/Sub"])
        #expect(LinkParser.links(in: "mega://file/AbCd?x=1#Key").map(\.0) == ["https://mega.nz/file/AbCd#Key"])
        #expect(LinkParser.links(in: "Is it https://mega.nz/file/AbCd#Key?").map(\.0) == ["https://mega.nz/file/AbCd#Key"])
        // A query never takes the key of the next link or of the page.
        #expect(LinkParser.links(in: "https://mega.nz/file/AAAA?x=1,https://mega.nz/file/BBBB#k2").map(\.0)
                == ["https://mega.nz/file/AAAA", "https://mega.nz/file/BBBB#k2"])
        #expect(LinkParser.links(in: ##"<a href="https://mega.nz/file/AAAA?x=1">a</a><a href="#top">"##).map(\.0)
                == ["https://mega.nz/file/AAAA"])
    }

    @Test func oneItemInTwoLinkFormsCountsOnce() {
        #expect(LinkParser.identity(of: "https://mega.nz/#F!AbCd!Key") == LinkParser.identity(of: "https://mega.co.nz/folder/AbCd#Key"))
        #expect(LinkParser.identity(of: "https://mega.nz/#!AbCd!Key") == LinkParser.identity(of: "https://mega.app/file/AbCd#Key"))
        #expect(LinkParser.identity(of: "https://mega.nz/file/AbCd#Key") != LinkParser.identity(of: "https://mega.nz/folder/AbCd#Key"))
        #expect(LinkParser.identity(of: "https://mega.nz/file/AbCd#Key") != LinkParser.identity(of: "https://mega.nz/file/AbCd#Other"))
        #expect(LinkParser.links(in: "https://mega.nz/#F!AbCd!Key\nhttps://www.mega.nz/folder/AbCd#Key").count == 1)
        var incoming = LinkSorter.Result(mega: ["https://mega.nz/file/a#k"])
        incoming.add(LinkSorter.Result(mega: ["https://mega.nz/file/a#k", "https://mega.nz/file/b#k"], protected: ["https://ouo.io/x"]))
        #expect(incoming.mega == ["https://mega.nz/file/a#k", "https://mega.nz/file/b#k"])
        #expect(incoming.protected == ["https://ouo.io/x"])
    }

    @Test(arguments: [
        "http://localhost/", "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.1/",
        "http://10.0.0.5/", "http://192.168.1.1/admin", "http://172.16.0.1/", "http://169.254.169.254/latest",
        "http://100.64.0.1/", "http://0.0.0.0/", "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/",
        "http://[::ffff:192.168.1.1]/", "http://[fe80::1%25en0]/", "http://[::1%25lo0]/",
        "http://printer.local/", "http://router/", "http://nas.home.arpa/",
        "file:///etc/hosts", "ftp://example.com/",
    ]) func bypassNeverOpensLocalAddresses(address: String) throws {
        #expect(!PublicAddress.allows(try #require(URL(string: address))))
    }

    @Test(arguments: [
        "https://example.com/", "https://linkvertise.com/123/abc", "http://8.8.8.8/", "https://[2606:4700::1111]/",
    ]) func bypassOpensPublicAddresses(address: String) throws {
        #expect(PublicAddress.allows(try #require(URL(string: address))))
    }

    @Test func apiKeyStaysOnItsHost() throws {
        let guardian = RedirectGuard(keyHeader: "x-api-key")
        let api = try #require(URL(string: "https://api.bypass.tools/api/v1/bypass/direct"))
        func redirect(to address: String) throws -> URLRequest? {
            var request = URLRequest(url: try #require(URL(string: address)))
            request.setValue("fixture-key", forHTTPHeaderField: "x-api-key")
            return guardian.redirect(request, from: api)
        }
        #expect(try redirect(to: "https://api.bypass.tools/api/v2/bypass")?.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
        #expect(try redirect(to: "https://other.example/collect")?.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(try redirect(to: "https://other.example/collect") != nil)
        #expect(try redirect(to: "http://api.bypass.tools/insecure")?.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(try redirect(to: "http://192.168.1.1/") == nil)
        // Page reads have no key, but the same local-network rule.
        #expect(RedirectGuard().redirect(URLRequest(url: try #require(URL(string: "http://127.0.0.1/"))), from: api) == nil)
    }

    @Test func separateKeyCopiesHaveNoKeyInTheLink() {
        let links = ["https://mega.nz/file/abc#key1", "https://mega.nz/folder/def#key2"]
        #expect(LinkPresentation.withoutKeys(links) == ["https://mega.nz/file/abc", "https://mega.nz/folder/def"])
        #expect(LinkPresentation.keys(of: links) == ["key1", "key2"])
    }

    @Test func longRemoteNamesFitTheFileSystem() {
        let name = String(repeating: "é", count: 300) + ".mp4"
        let safe = LocalFileSafety.filename(name)
        #expect(safe.utf8.count <= 255)
        #expect(safe.hasSuffix(".mp4"))
        // The " (2)" that the SDK adds to a name in use still fits.
        #expect(safe.utf8.count + " (99)".utf8.count <= 255)
        #expect(LocalFileSafety.filename("short.txt") == "short.txt")
        // 90 CJK characters are 270 bytes: whole characters are cut, the extension stays.
        let cjk = LocalFileSafety.filename(String(repeating: "日", count: 90) + ".pdf")
        #expect(cjk.utf8.count <= 255 && cjk.hasPrefix("日日") && cjk.hasSuffix("日.pdf"))
        let bare = LocalFileSafety.filename(String(repeating: "a", count: 400))
        #expect(bare.utf8.count + " (99)".utf8.count <= 255 && bare.allSatisfy { $0 == "a" })
        // 200 bytes, but 300 UTF-16 units when decomposed, as the SDK writes it.
        let marks = LocalFileSafety.filename(String(repeating: "\u{01D8}", count: 100) + ".txt")
        #expect(marks.hasSuffix(".txt") && marks.decomposedStringWithCanonicalMapping.utf16.count <= 240)
        #expect(LocalFileSafety.filename(String(repeating: "x", count: 236) + ".txt").count == 240)
    }

    @Test func shortenedNamesCanBeWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "megaglass-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let long = ["é", "日", "😀", "\u{01D8}", "한", "a"].map { String(repeating: $0, count: 400) + ".pdf" }
        for name in long {
            let safe = LocalFileSafety.filename(name)
            #expect(safe.utf8.count <= 255 && safe.hasSuffix(".pdf"))
            // As the SDK writes it, with the suffix of a name in use.
            for leaf in [safe, (safe as NSString).deletingPathExtension + " (99).pdf"] {
                #expect(FileManager.default.createFile(atPath: folder.appending(path: leaf).path, contents: nil))
            }
        }
    }

    @Test func remoteNamesLoseDirectionMarksAndControls() {
        #expect(LocalFileSafety.displayName("invoice\u{202E}fdp.terminal") == "invoicefdp.terminal")
        let marks = "\u{061C}\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2060}\u{2061}\u{2064}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"
        #expect(LocalFileSafety.displayName("a" + marks + "b.txt") == "ab.txt")
        #expect(LocalFileSafety.displayName("a\nb\u{0}\u{1B}\u{7F}\u{85}\u{9F}.txt")
                == "a\u{FFFD}b\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}.txt")
        #expect(LocalFileSafety.displayName("invoice.pdf\u{2028}.terminal") == "invoice.pdf\u{FFFD}.terminal")
        #expect(LocalFileSafety.displayName("日本語 😀 Ünïcode – ok.txt") == "日本語 😀 Ünïcode – ok.txt")
        // The same rules give the names on disk.
        #expect(LocalFileSafety.filename("photo\u{202E}gpj.app") == "photogpj.app")
        #expect(LocalFileSafety.filename("\u{202E}\u{200F}") == "Untitled")
        // The browser shows the real type.
        let item = NodeItem(id: 1, name: "invoice\u{202E}fdp.terminal")
        #expect(item.name == "invoicefdp.terminal")
        #expect(item.kind == .other && item.kindTitle != "Document")
        #expect(NodeItem(id: 2, name: "data.zq9x").kindTitle == "ZQ9X File")
        #expect(NodeItem(id: 3, name: "report.pdf").kindTitle == "PDF Document")
    }

    @Test func finishedDownloadsAreQuarantined() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "megaglass-\(UUID().uuidString).command")
        try Data("echo test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        LocalFileSafety.quarantine(file)
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }

    @Test func previewSkipsTypesWithoutAPreview() {
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 1, name: "backup.r00"), allowLarge: false)?.canForce == false)
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 2, name: "mail.eml"), allowLarge: false)?.canForce == false)
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 3, name: "tool.exe"), allowLarge: false)?.canForce == false)
        // Text and code with an extension that macOS does not know show as text.
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 4, name: "release.nfo"), allowLarge: false) == nil)
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 5, name: "config.toml"), allowLarge: false) == nil)
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 6, name: "report.pdf"), allowLarge: false) == nil)
        #expect(PreviewView.noAutomaticPreview(NodeItem(id: 7, name: "big.pdf", size: 300_000_000), allowLarge: false)?.canForce == true)
    }

    @Test func incomingAddressesCountOnlyThemselves() throws {
        let hosts = Set(LinkSorter.defaultProtectorHosts)
        func incoming(_ address: String) throws -> LinkSorter.Result {
            LinkSorter.incoming(try #require(URL(string: address)), protectorHosts: hosts)
        }
        #expect(try incoming("mega://folder/abc#key").mega == ["https://mega.nz/folder/abc#key"])
        #expect(try incoming("https://mega.nz/file/abc#key").mega == ["https://mega.nz/file/abc#key"])
        // A mega:// address never goes to Bypass.
        #expect(try incoming("mega://x?u=https://ouo.io/AbCdE").isEmpty)
        // Links in the query of another site do not count: the browser opens the page.
        #expect(try incoming("https://duckduckgo.com/?q=https://mega.nz/file/abc#key").isEmpty)
        #expect(try incoming("https://example.com/?r=https://ouo.io/AbCdE").isEmpty)
        // Home, account and password pages of a protector site go to the browser.
        #expect(try incoming("https://linkvertise.com/").isEmpty)
        #expect(try incoming("https://linkvertise.com/reset-password?token=fixture").isEmpty)
        #expect(try incoming("https://publisher.linkvertise.com/dashboard").isEmpty)
        #expect(try incoming("https://linkvertise.com/123/abc").protected == ["https://linkvertise.com/123/abc"])
        #expect(try incoming("https://lootdest.org/s?abc").protected == ["https://lootdest.org/s?abc"])
        let copied = LinkSorter.sort("https://work.ink/login https://ouo.io/AbCdE", protectorHosts: hosts)
        #expect(copied.protected == ["https://ouo.io/AbCdE"])
    }

    @Test func fatalEngineErrorsExplainTheRestart() {
        #expect(MegaFailure.fatalErrorMessage(reason: 3)?.contains("disk is full") == true)
        #expect(MegaFailure.fatalErrorMessage(reason: 2) != nil)
        #expect(MegaFailure.fatalErrorMessage(reason: -1) != nil)
        // Sync settings problems stop no sync.
        #expect(MegaFailure.fatalErrorMessage(reason: 5) == nil)
        #expect(MegaFailure.fatalErrorMessage(reason: 6) == nil)
    }

    @Test func megaSchemeLinksNeedABoundary() {
        #expect(LinkParser.links(in: "omega://folder/abc#key").isEmpty)
        #expect(LinkParser.links(in: #"<a href="mega://folder/abc#key">x</a>"#).first?.0 == "https://mega.nz/folder/abc#key")
    }

    @Test func pageScanReadsLinksAndSurvivesAHungPage() async throws {
        let browser = BypassBrowser()
        defer { browser.stop() }
        browser.webView.loadHTMLString(#"<a href="https://mega.nz/file/abc#key">file</a>"#, baseURL: nil)
        await browser.waitUntilLoaded(timeout: 10)
        let page = try #require(await browser.scan(resultSelector: nil))
        #expect(page.mega == ["https://mega.nz/file/abc#key"])

        // An endless script blocks the page: the scan gives up in time instead of waiting forever.
        browser.webView.loadHTMLString("<script>setTimeout(() => { for (;;) {} }, 100)</script>", baseURL: nil)
        await browser.waitUntilLoaded(timeout: 10)
        try await Task.sleep(for: .milliseconds(500))
        let start = ContinuousClock.now
        #expect(await browser.scan(resultSelector: nil) == nil)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func captchaServicesWaitForYou() {
        let byID = Dictionary(uniqueKeysWithValues: BypassProvider.all.map { ($0.id, $0) })
        #expect(byID["bypass.vip"]?.withYouOnly == true)
        #expect(byID["bypass.link"]?.withYouOnly == true)
        #expect(byID["bypass.city"]?.withYouOnly == false)
        #expect(byID["bypass.tools"]?.withYouOnly == false)
    }

    @Test func bypassToolsRepliesAreRead() throws {
        let provider = try #require(BypassProvider.all.first { $0.id == "bypass.tools-api" })
        #expect(provider.needsKey && provider.isAPI)
        func object(_ json: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let success = BypassCenter.APIReply(status: 200, object: try object(
            #"{"status":"success","result":"https://mega.nz/file/abc#key","cached":false,"processTime":2341,"requestId":"r"}"#))
        #expect(success.success == true)
        #expect(success.result == "https://mega.nz/file/abc#key")
        let quota = BypassCenter.APIReply(status: 403, object: try object(
            #"{"status":"error","message":"Quota exceeded","code":"QUOTA_EXCEEDED"}"#))
        #expect(quota.success == false)
        #expect(quota.message == "Quota exceeded")
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
    try encodedImage("public.png")
}

nonisolated private func encodedImage(_ type: String, width: Int = 1, height: Int = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
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

    @Test func attributesDecodeOnlyMEGATypesWithinSize() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "megaglass-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ data: Data) throws -> URL {
            // The cache names every attribute .jpg: the content decides the type.
            let url = root.appending(path: UUID().uuidString + ".jpg")
            try data.write(to: url)
            return url
        }
        for type in ["public.jpeg", "public.png"] {
            let url = try file(encodedImage(type))
            #expect(ThumbnailStore.decodeAttribute(url, preview: false) != nil)
            #expect(ThumbnailStore.decodeAttribute(url, preview: true) != nil)
        }
        for type in ["public.tiff", "com.compuserve.gif", "com.microsoft.bmp"] {
            let url = try file(encodedImage(type))
            #expect(ThumbnailStore.decodeAttribute(url, preview: false) == nil)
            #expect(ThumbnailStore.decodeAttribute(url, preview: true) == nil)
            // Full images that the user opens can have any type.
            #expect(ThumbnailStore.decode(url, maxPixelSize: 64) != nil)
        }
        let wide = try file(encodedImage("public.png", width: 2000))
        #expect(ThumbnailStore.decodeAttribute(wide, preview: false) == nil)
        #expect(ThumbnailStore.decodeAttribute(wide, preview: true) != nil)
        let huge = try file(encodedImage("public.png", width: 1, height: 5000))
        #expect(ThumbnailStore.decodeAttribute(huge, preview: true) == nil)
        #expect(ThumbnailStore.decodeAttribute(try file(Data("not an image".utf8)), preview: false) == nil)
    }

    @Test func otherImageTypeIsNotShownOrCached() async throws {
        let (engine, root) = try makeEngine()
        defer { engine.shutdown(); try? FileManager.default.removeItem(at: root) }
        let writer = AttributeWriter(image: try encodedImage("public.tiff"))
        let store = ThumbnailStore(sdk: engine.sdk, directory: root.appending(path: "isolated-cache"),
                                   fetchAttribute: { _, _, _, url in try await writer.write(url) })
        #expect(await store.thumbnail(42) == nil)
        #expect(store.cached(42) == nil)
        #expect(await store.thumbnail(42) == nil)
        #expect(await writer.count == 2)
    }
}

@MainActor
struct SyncRootTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    // Not on disk: the check falls back to the plain path.
    private var base: URL { home.appending(path: "megaglass-sync-test-" + UUID().uuidString) }

    @Test func systemAndHomeFoldersAreRefused() {
        for folder in ["/", "/Users", "/Volumes", "/System/Library", "/Library", "/Applications/Safari.app",
                       "/usr/local", "/tmp", "/private/var", "/etc"] {
            #expect(SyncCenter.rootProblem(URL(filePath: folder), otherRoots: [], appFolders: []) != nil, "\(folder)")
        }
        #expect(SyncCenter.rootProblem(home, otherRoots: [], appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(home.appending(path: "Library"), otherRoots: [], appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(home.appending(path: "Library/LaunchAgents"), otherRoots: [], appFolders: []) != nil)
        // Letter case and "..": the same folder.
        let shouted = URL(filePath: home.path(percentEncoded: false).uppercased()).appending(path: "LIBRARY")
        #expect(SyncCenter.rootProblem(shouted, otherRoots: [], appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(home.appending(path: "Documents/../Library"), otherRoots: [], appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(base.appending(path: "Documents"), otherRoots: [], appFolders: []) == nil)
    }

    @Test func symlinkToAProtectedFolderIsRefused() throws {
        let link = FileManager.default.temporaryDirectory.appending(path: "megaglass-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Library"))
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(SyncCenter.rootProblem(link, otherRoots: [], appFolders: []) != nil)
    }

    @Test func appDataFoldersAreRefused() {
        let base = base
        let support = base.appending(path: "support")
        let apps = [support, base.appending(path: "caches")]
        #expect(SyncCenter.rootProblem(support, otherRoots: [], appFolders: apps) != nil)
        #expect(SyncCenter.rootProblem(support.appending(path: "engine"), otherRoots: [], appFolders: apps) != nil)
        #expect(SyncCenter.rootProblem(base, otherRoots: [], appFolders: apps) != nil)
        #expect(SyncCenter.rootProblem(base.appending(path: "support-old"), otherRoots: [], appFolders: apps) == nil)
    }

    @Test func overlappingSyncRootsAreRefused() {
        let base = base
        let work = base.appending(path: "Documents/Work")
        let others = [work.path(percentEncoded: false)]
        #expect(SyncCenter.rootProblem(work, otherRoots: others, appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(work.appending(path: "Sub"), otherRoots: others, appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(base.appending(path: "Documents"), otherRoots: others, appFolders: []) != nil)
        #expect(SyncCenter.rootProblem(base.appending(path: "Documents/Work 2"), otherRoots: others, appFolders: []) == nil)
    }

    @Test func stallTextIsForPeople() {
        // FileIssue with FilesystemErrorListingFolder: a scan-blocked folder.
        #expect(SyncCenter.describeStall(reason: 1, problems: [18]).contains("System Settings"))
        // DeletedOrMovedByUser only tells what happened; WaitingForAnotherMoveToComplete is the cause.
        #expect(SyncCenter.describeStall(reason: 2, problems: [14, 21]) == "Waiting for another move to finish.")
        #expect(SyncCenter.describeStall(reason: 3, problems: []) == "Waiting for the folder scan to finish.")
        #expect(SyncCenter.describeStall(reason: 99, problems: [99]) == "This item cannot be synced.")
    }
}
