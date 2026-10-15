import Foundation
import Security

nonisolated enum AppPaths {
    static let bundleID = "app.megaglass.MegaGlass"

    #if MEGAGLASS_TESTS
    /// Test builds keep all engine data in their own folder.
    private static let testRoot = ProcessInfo.processInfo.environment["MEGAGLASS_TEST_DATA"].map { URL(filePath: $0) }
    #else
    private static let testRoot: URL? = nil
    #endif

    static let support = testRoot?.appending(path: "support", directoryHint: .isDirectory)
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "MegaGlass", directoryHint: .isDirectory)
    static let caches = testRoot?.appending(path: "caches", directoryHint: .isDirectory)
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: bundleID, directoryHint: .isDirectory)

    /// Engine state of the account (node cache, transfers, syncs).
    static var accountEngine: URL { ensure(support.appending(path: "engine", directoryHint: .isDirectory)) }
    static func linkEngine(_ id: String) -> URL { ensure(caches.appending(path: "links/\(id)", directoryHint: .isDirectory)) }
    static func thumbnails(_ scope: String) -> URL { ensure(caches.appending(path: "thumbnails/\(scope)", directoryHint: .isDirectory)) }
    static var previews: URL { ensure(caches.appending(path: "previews", directoryHint: .isDirectory)) }
    static var avatars: URL { ensure(caches.appending(path: "avatars", directoryHint: .isDirectory)) }

    /// Decrypted content lives in folders that only this user can read.
    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    static func removeAll(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Empties a folder and keeps it (an engine still uses the folder).
    static func removeContents(of url: URL) {
        for item in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            removeAll(at: item)
        }
    }
}

/// Stores the session token. The password is never stored.
nonisolated enum Keychain {
    static let sessionService = "app.megaglass.session"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain operation failed (\(status))." }
    }

    static func save(_ value: String, account: String, service: String = sessionService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // No effect in the login Keychain (the item ACL controls access); it applies
            // when a Developer ID build moves to the data protection Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    static func read(account: String, service: String = sessionService) -> String? {
        try? load(account: account, service: service)
    }

    static func load(account: String, service: String = sessionService) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return value
    }

    static func delete(account: String, service: String = sessionService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
