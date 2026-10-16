import CoreServices
import Foundation

nonisolated enum LocalFileSafety {
    /// Whoever uploads a file chooses its name. Direction marks can show "invoice\u{202E}fdp.app"
    /// as "invoiceppa.pdf", and control characters and line breaks can hide a part of a name.
    /// Names on screen and on disk drop the marks and replace the controls with U+FFFD.
    static func displayName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.value {
            // Not U+200C and U+200D: emoji sequences and many scripts need them.
            case 0x061C, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: continue
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: scalars.append("\u{FFFD}")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The local name of a download or a preview: a single component that fits the file
    /// system. On APFS, the SDK escapes only "/".
    static func filename(_ name: String) -> String {
        let cleaned = displayName(name).replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "Untitled" }
        return shortened(cleaned)
    }

    /// The SDK writes a name decomposed. APFS, HFS+, exFAT, FAT and NTFS allow 255 UTF-16 units
    /// of that form. A longer name keeps its extension, and room stays for the " (2)" that the
    /// SDK adds when the name is already in use.
    private static func shortened(_ name: String, limit: Int = 240) -> String {
        func size(_ text: String) -> Int {
            // On exFAT, FAT, NTFS and network disks, the SDK writes each of these as "%xx".
            let escaped = 2 * text.unicodeScalars.count(where: { #"\?"<>|*"#.unicodeScalars.contains($0) })
            return text.decomposedStringWithCanonicalMapping.utf16.count + escaped
        }
        guard size(name) > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var used = size(suffix)
        var stem = ""
        // Whole characters from the start, while they fit: one pass, also for a very long name.
        for character in suffix.isEmpty ? name : String(name.dropLast(suffix.count)) {
            let next = size(String(character))
            guard used + next <= limit else { break }
            used += next
            stem.append(character)
        }
        return stem.isEmpty ? "Untitled" + suffix : stem + suffix
    }

    /// Marks a downloaded file as from the internet, as a browser does: Gatekeeper then checks
    /// the apps, installers and scripts in it before they open. No origin URL: a link holds its key.
    static func quarantine(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "MegaGlass",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        try? url.setResourceValues(values)
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
