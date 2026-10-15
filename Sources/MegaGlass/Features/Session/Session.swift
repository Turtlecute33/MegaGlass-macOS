import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

nonisolated struct AccountSummary: Sendable {
    let plan: String
    let isPaid: Bool
    let storageUsed: Int64
    let storageMax: Int64
    let transferUsed: Int64
    let transferMax: Int64
    let cloudUsed: Int64
    let rubbishUsed: Int64
    let backupsUsed: Int64
    let incomingUsed: Int64
    let versionsUsed: Int64
    let renews: Date?

    var storageFraction: Double { storageMax > 0 ? min(1, Double(storageUsed) / Double(storageMax)) : 0 }
    var transferFraction: Double { transferMax > 0 ? min(1, Double(transferUsed) / Double(transferMax)) : 0 }

    static func planName(_ type: MEGAAccountType) -> String {
        switch type {
        case .free: "Free"
        case .proI: "Pro I"
        case .proII: "Pro II"
        case .proIII: "Pro III"
        case .lite: "Pro Lite"
        case .starter: "Starter"
        case .basic: "Basic"
        case .essential: "Essential"
        case .business: "Business"
        case .proFlexi: "Pro Flexi"
        default: "MEGA"
        }
    }
}

/// The authentication boundary is injectable so lifecycle races can be tested offline.
@MainActor
protocol SessionAuthentication {
    var email: String? { get }
    func restore(_ token: String) async throws
    func login(email: String, password: String, code: String?) async throws
    func fetchNodes(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func logout() async throws
    func localLogout() async throws
    func dumpSession() -> String?
}

private struct SDKSessionAuthentication: SessionAuthentication {
    let sdk: MEGASdk
    var email: String? { sdk.myEmail }
    func restore(_ token: String) async throws {
        _ = try await sdk.request { sdk.fastLogin(withSession: token, delegate: $0) }
    }
    func login(email: String, password: String, code: String?) async throws {
        if let code, !code.isEmpty {
            _ = try await sdk.request { sdk.multiFactorAuthLogin(withEmail: email, password: password, pin: code, delegate: $0) }
        } else {
            _ = try await sdk.request { sdk.login(withEmail: email, password: password, delegate: $0) }
        }
    }
    func fetchNodes(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        _ = try await sdk.request(progress: progress) { sdk.fetchNodes(with: $0) }
    }
    func logout() async throws {
        let sdk = sdk
        _ = try await RequestDeadline.run(for: .seconds(10)) {
            try await sdk.request(accepting: [.apiESid]) { sdk.logout(with: $0) }
        }
    }
    func localLogout() async throws {
        let sdk = sdk
        _ = try await RequestDeadline.run(for: .seconds(10)) {
            try await sdk.request(accepting: [.apiESid]) { sdk.localLogout(with: $0) }
        }
    }
    func dumpSession() -> String? { sdk.dumpSession() }
}

@MainActor
protocol SessionCredentials {
    func read() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

struct KeychainSessionCredentials: SessionCredentials {
    private static let restoreDisabledKey = "sessionRestoreDisabled"
    private let defaults: UserDefaults
    private let loadToken: () throws -> String?
    private let saveToken: (String) throws -> Void
    private let removeToken: () throws -> Void

    init(defaults: UserDefaults = .standard,
         load: @escaping () throws -> String? = { try Keychain.load(account: "session") },
         save: @escaping (String) throws -> Void = { try Keychain.save($0, account: "session") },
         remove: @escaping () throws -> Void = { try Keychain.delete(account: "session") }) {
        self.defaults = defaults
        loadToken = load
        saveToken = save
        removeToken = remove
    }

    func read() throws -> String? {
        guard !defaults.bool(forKey: Self.restoreDisabledKey) else { return nil }
        return try loadToken()
    }

    func save(_ token: String) throws {
        // If updating credentials is denied, an older account token must not be
        // silently restored on the next launch. Only successful persistence re-enables it.
        defaults.set(true, forKey: Self.restoreDisabledKey)
        try saveToken(token)
        defaults.set(false, forKey: Self.restoreDisabledKey)
    }

    func delete() throws {
        // Keychain ACL denial must not turn local logout into auto-login on relaunch.
        // This is a nonsensitive boolean; tokens remain exclusively in the Keychain.
        defaults.set(true, forKey: Self.restoreDisabledKey)
        try removeToken()
    }
}

/// Login state of the account engine.
@Observable
final class Session {
    enum Phase: Equatable {
        case starting
        case signedOut
        case signingIn
        case loadingAccount(Double?)
        case ready
    }


    private(set) var phase: Phase = .starting
    /// Browse links and download without an account.
    var isGuest = false
    private(set) var email: String?
    private(set) var displayName: String?
    private(set) var account: AccountSummary?
    private(set) var twoFactorEnabled: Bool?
    var startupMessage: String?

    private(set) var isSigningOut = false
    @ObservationIgnored private var authenticating = false
    @ObservationIgnored private var fetchingNodes = false
    private(set) var generation = UUID()
    @ObservationIgnored private let authentication: any SessionAuthentication
    @ObservationIgnored private let credentials: any SessionCredentials
    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored let engine: MegaEngine
    @ObservationIgnored var onSignedIn: (() -> Void)?
    @ObservationIgnored var onSignedOut: (() -> Void)?

    private var sdk: MEGASdk { engine.sdk }

    init(engine: MegaEngine, authentication: (any SessionAuthentication)? = nil,
         credentials: (any SessionCredentials)? = nil) {
        self.engine = engine
        self.authentication = authentication ?? SDKSessionAuthentication(sdk: engine.sdk)
        self.credentials = credentials ?? KeychainSessionCredentials()
        engine.onSessionExpired = { [weak self] in
            Task {
                guard let self, !self.isSigningOut, !self.authenticating,
                      self.phase != .signedOut, self.phase != .starting else { return }
                self.startupMessage = "Your session has expired. Log in again."
                await self.signOut()
            }
        }
        engine.onReloadNeeded = { [weak self] in
            Task {
                guard let self, self.isSignedIn, !self.isSigningOut else { return }
                let generation = self.generation
                do { try await self.fetchNodes() } catch {
                    guard generation == self.generation, !self.isSigningOut else { return }
                    self.phase = .ready
                    self.onError?(error)
                }
            }
        }
    }

    var isSignedIn: Bool { phase == .ready }

    /// Resumes the saved session. The local node cache makes this fast.
    func start() async {
        // Session transactions outlive the window task that requested them. Canceling
        // a waiter cannot cancel an SDK login already sent to the server.
        await Task { await restoreSession() }.value
    }

    private func restoreSession() async {
        guard phase == .starting, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let saved: String?
        do { saved = try credentials.read() }
        catch { startupMessage = error.localizedDescription; phase = .signedOut; return }
        guard let session = saved else {
            phase = .signedOut
            return
        }
        phase = .loadingAccount(nil)
        var restored = false
        do {
            try await authentication.restore(session)
            restored = true
            try await fetchNodes()
        } catch let failure as MegaFailure {
            if restored { try? await authentication.localLogout() }
            // Keep the session for network problems; drop it when the server rejects it.
            #if MEGAGLASS_TESTS
            let mayDrop = false // Test builds never change the saved session.
            #else
            let mayDrop = true
            #endif
            if mayDrop, failure.isBadSession || failure.code == MEGAErrorType.apiENoent.rawValue
                || failure.code == MEGAErrorType.apiEBlocked.rawValue {
                do { try credentials.delete() } catch { onError?(error) }
            }
            startupMessage = failure.message
            phase = .signedOut
        } catch {
            if restored { try? await authentication.localLogout() }
            startupMessage = error.localizedDescription
            phase = .signedOut
        }
    }

    /// Throws `MegaFailure` with `needsTwoFactorCode` when the account uses 2FA and no code was given.
    func signIn(email: String, password: String, code: String?) async throws {
        try Task.checkCancellation()
        try await Task { try await signInTransaction(email: email, password: password, code: code) }.value
    }

    private func signInTransaction(email: String, password: String, code: String?) async throws {
        guard phase == .signedOut, !authenticating, !isSigningOut else {
            throw MegaFailure(code: -1, message: "Another session operation is in progress.")
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty else {
            throw MegaFailure(code: -2, message: "Enter your email and password.")
        }
        authenticating = true
        engine.resetEvents()
        generation = UUID()
        phase = .signingIn
        defer { authenticating = false }
        var loggedIn = false
        do {
            try await authentication.login(email: email, password: password, code: code)
            loggedIn = true
            if let token = authentication.dumpSession() {
                // Failure to remember a session must be visible, but need not lose a login.
                do { try credentials.save(token) } catch { onError?(error) }
            }
            try await fetchNodes()
        } catch {
            if loggedIn { try? await authentication.localLogout() }
            phase = .signedOut
            throw error
        }
    }

    func signOut() async {
        await Task { await signOutTransaction() }.value
    }

    private func signOutTransaction() async {
        guard phase != .signedOut, phase != .starting, !isSigningOut, !authenticating else { return }
        isSigningOut = true
        generation = UUID() // Invalidate profile, quota and progress callbacks immediately.
        defer { isSigningOut = false }
        do {
            try await authentication.logout()
        } catch {
            // A local logout clears cached credentials even when the network is unavailable.
            do { try await authentication.localLogout() } catch {
                onError?(error)
                return
            }
        }
        do { try credentials.delete() } catch { onError?(error) }
        engine.resetEvents()
        engine.thumbnails.clear()
        email = nil
        displayName = nil
        account = nil
        twoFactorEnabled = nil
        isGuest = false
        phase = .signedOut
        onSignedOut?()
    }

    private func fetchNodes() async throws {
        guard !fetchingNodes, !isSigningOut, phase != .signedOut else { return }
        fetchingNodes = true
        defer { fetchingNodes = false }
        let generation = generation
        phase = .loadingAccount(nil)
        try await authentication.fetchNodes { [weak self] done, total in
            guard total > 0 else { return }
            let fraction = min(1, max(0, Double(done) / Double(total)))
            Task { @MainActor in
                guard let self, self.generation == generation, self.fetchingNodes, !self.isSigningOut else { return }
                self.phase = .loadingAccount(fraction)
            }
        }
        guard generation == self.generation, !isSigningOut else { throw CancellationError() }
        email = authentication.email
        isGuest = false
        phase = .ready
        onSignedIn?()
        Task { await refreshAccount() }
        Task { await loadProfile() }
    }

    func refreshAccount() async {
        guard isSignedIn, !isSigningOut, sdk.myEmail != nil else { return }
        let generation = generation
        let sdk = self.sdk
        guard let request = try? await sdk.request({ sdk.getAccountDetails(with: $0) }),
              let details = request.megaAccountDetails else { return }
        let summary = await EngineQueue.run {
            let root = sdk.rootNode?.handle ?? invalidHandle
            let rubbish = sdk.rubbishNode?.handle ?? invalidHandle
            let vault = sdk.vaultNode?.handle ?? invalidHandle
            let cloud = details.storageUsed(forHandle: root)
            let trash = details.storageUsed(forHandle: rubbish)
            let backups = details.storageUsed(forHandle: vault)
            return AccountSummary(
                plan: AccountSummary.planName(details.type),
                isPaid: details.type != .free,
                storageUsed: details.storageUsed,
                storageMax: details.storageMax,
                transferUsed: details.transferUsed,
                transferMax: details.transferMax,
                cloudUsed: cloud,
                rubbishUsed: trash,
                backupsUsed: backups,
                incomingUsed: max(0, details.storageUsed - cloud - trash - backups - details.versionStorageUsed),
                versionsUsed: details.versionStorageUsed,
                renews: details.proExpiration > 0 ? Date(timeIntervalSince1970: TimeInterval(details.proExpiration)) : nil)
        }
        guard generation == self.generation, isSignedIn, !isSigningOut else { return }
        account = summary
    }

    private func loadProfile() async {
        guard isSignedIn, !isSigningOut, sdk.myEmail != nil else { return }
        let generation = generation
        let sdk = self.sdk
        let first = try? await sdk.request { sdk.getUserAttributeType(.firstname, delegate: $0) }.text
        let last = try? await sdk.request { sdk.getUserAttributeType(.lastname, delegate: $0) }.text
        let name = [first, last].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        guard generation == self.generation, isSignedIn, !isSigningOut else { return }
        displayName = name.isEmpty ? nil : name
        await refreshTwoFactor()
    }

    // MARK: Two-factor authentication

    func refreshTwoFactor() async {
        guard let email, isSignedIn, !isSigningOut else { return }
        let generation = generation
        let sdk = self.sdk
        let enabled = try? await sdk.request { sdk.multiFactorAuthCheck(withEmail: email, delegate: $0) }.flag
        guard generation == self.generation, isSignedIn, !isSigningOut else { return }
        twoFactorEnabled = enabled
    }

    /// Returns the shared secret for the authenticator app.
    func twoFactorSecret() async throws -> String {
        let sdk = self.sdk
        return try await sdk.request { sdk.multiFactorAuthGetCode(with: $0) }.text ?? ""
    }

    func enableTwoFactor(code: String) async throws {
        let sdk = self.sdk
        _ = try await sdk.request { sdk.multiFactorAuthEnable(withPin: code, delegate: $0) }
        await refreshTwoFactor()
    }

    func disableTwoFactor(code: String) async throws {
        let sdk = self.sdk
        _ = try await sdk.request { sdk.multiFactorAuthDisable(withPin: code, delegate: $0) }
        await refreshTwoFactor()
    }

    func changePassword(current: String, new: String, code: String?) async throws {
        let sdk = self.sdk
        if let code, !code.isEmpty {
            _ = try await sdk.request { sdk.multiFactorAuthChangePassword(current, newPassword: new, pin: code, delegate: $0) }
        } else {
            _ = try await sdk.request { sdk.changePassword(current, newPassword: new, delegate: $0) }
        }
    }
}
