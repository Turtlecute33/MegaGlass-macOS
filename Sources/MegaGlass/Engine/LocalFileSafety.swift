import Foundation

nonisolated enum LocalFileSafety {
    /// A remote name must stay a single local component. The SDK performs its own
    /// escaping for ordinary transfers; previews pass this explicit safe filename.
    static func filename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "Preview" }
        return cleaned
    }

    static func validateDownloadDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
        // URL resource values can cache writability across a chmod or volume change.
        guard FileManager.default.isWritableFile(atPath: url.path) else { throw CocoaError(.fileWriteNoPermission) }
    }
}
