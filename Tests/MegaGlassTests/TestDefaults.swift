import Foundation

/// Removes a test defaults suite. `removePersistentDomain` leaves an empty plist in
/// ~/Library/Preferences, so this also deletes the file.
func removeTestDefaults(_ suite: String) {
    UserDefaults().removePersistentDomain(forName: suite)
    CFPreferencesAppSynchronize(suite as CFString)
    try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(suite).plist"))
}
