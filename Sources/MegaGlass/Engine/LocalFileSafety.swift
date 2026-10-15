import Foundation

nonisolated enum LocalFileSafety {
    /// A remote name must stay a single local component. The SDK performs its own
    /// escaping for ordinary transfers; previews pass this explicit safe filename.
    static func filename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "Preview" }
        return shortened(cleaned)
    }

    /// macOS names have at most 255 UTF-8 bytes: a longer name keeps its extension.
    private static func shortened(_ name: String, limit: Int = 255) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > limit { stem.removeLast() }
        return stem.isEmpty ? "Preview" + suffix : stem + suffix
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
