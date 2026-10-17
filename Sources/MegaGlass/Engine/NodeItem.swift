import AppKit
@preconcurrency import MEGASdk
import UniformTypeIdentifiers

/// A light, immutable copy of a node for the UI. Lists are built on a background queue,
/// so views never call into the engine while they draw.
nonisolated struct NodeItem: Identifiable, Hashable, Sendable {
    let id: UInt64
    let name: String
    let isFolder: Bool
    let size: Int64
    let modified: Date
    let created: Date
    /// Only for the kinds that MEGA makes pictures of. On other files, a picture that the
    /// uploader set would hide the real type ("invoice.pdf" art on a script).
    let hasThumbnail: Bool
    let hasPreview: Bool
    let label: Int
    let isFavourite: Bool
    let isExported: Bool
    let isOutShare: Bool
    let isInShare: Bool
    let isTakenDown: Bool
    let parentHandle: UInt64
    let restoreHandle: UInt64
    let kind: FileKind
    /// What the file is. Types that the app does not group get the name that macOS gives
    /// them ("Terminal settings"): "Document" would hide what they are.
    let kindTitle: String
    /// Length of a video or audio file in seconds; 0 when it is not known.
    let duration: Int

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isShared: Bool { isOutShare || isInShare }

    init(id: UInt64, name: String, isFolder: Bool = false, size: Int64 = 0,
         modified: Date = .distantPast) {
        self.id = id
        self.name = LocalFileSafety.displayName(name)
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        created = modified
        hasThumbnail = false
        hasPreview = false
        label = 0
        isFavourite = false
        isExported = false
        isOutShare = false
        isInShare = false
        isTakenDown = false
        parentHandle = invalidHandle
        restoreHandle = invalidHandle
        let ext = (self.name as NSString).pathExtension.lowercased()
        kind = isFolder ? .folder : FileKind(extension: ext)
        kindTitle = kind.title(extension: ext)
        duration = 0
    }

    init(_ node: MEGANode, folderSize: Int64? = nil) {
        id = node.handle
        name = LocalFileSafety.displayName(node.name ?? "Untitled")
        isFolder = node.isFolder()
        let ext = (name as NSString).pathExtension.lowercased()
        kind = isFolder ? .folder : FileKind(extension: ext)
        kindTitle = kind.title(extension: ext)
        // The node size of a folder is not the size of its contents.
        size = folderSize ?? (isFolder ? 0 : node.size?.int64Value ?? 0)
        created = node.creationTime ?? .distantPast
        modified = node.isFile() ? (node.modificationTime ?? created) : created
        hasThumbnail = kind.hasPictures && node.hasThumbnail()
        hasPreview = kind.hasPictures && node.hasPreview()
        label = node.label.rawValue
        isFavourite = node.isFavourite
        isExported = node.isExported()
        isOutShare = node.isOutShare()
        isInShare = node.isInShare()
        isTakenDown = node.isTakenDown()
        parentHandle = node.parentHandle
        restoreHandle = node.restoreHandle
        // From the file's media attributes, decrypted with its key: no download.
        duration = kind.isStreamable ? max(0, node.duration) : 0
    }
}

nonisolated enum FileKind: String, Sendable, CaseIterable {
    case folder, image, video, audio, pdf, document, spreadsheet, presentation, archive, code, text, other

    init(extension ext: String) {
        switch ext {
        case "jpg", "jpeg", "jpe", "png", "gif", "heic", "heif", "hif", "webp", "tif", "tiff", "bmp", "avif",
             "jp2", "j2k", "svg", "raw", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
             "orf", "rw2", "pef", "srw", "3fr", "erf", "mrw", "psd", "ico", "icns", "tga", "exr", "jxl":
            self = .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "3gp", "3g2", "mpg", "mpeg", "ts", "mts":
            self = .video
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac":
            self = .audio
        case "pdf": self = .pdf
        case "doc", "docx", "pages", "odt", "rtf", "rtfd": self = .document
        case "xls", "xlsx", "numbers", "ods", "csv", "tsv": self = .spreadsheet
        case "ppt", "pptx", "key", "odp": self = .presentation
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg", "iso", "pkg": self = .archive
        case "swift", "js", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm",
             "java", "kt", "cs", "php", "html", "css", "scss", "json", "xml", "yml", "yaml", "toml", "sh",
             "zsh", "sql", "lua":
            self = .code
        case "txt", "md", "markdown", "log", "ini", "conf", "nfo", "srt", "vtt":
            self = .text
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .folder: "Folder"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF Document"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .archive: "Archive"
        case .code: "Source Code"
        case .text: "Text"
        case .other: "Document"
        }
    }

    var isStreamable: Bool { self == .video || self == .audio }

    /// The kinds that MEGA clients make thumbnails and previews for (audio: the cover).
    var hasPictures: Bool { self == .image || self == .video || self == .audio || self == .pdf }

    /// The title for a file of this kind with this extension.
    func title(extension ext: String) -> String {
        guard self == .other, !ext.isEmpty else { return title }
        guard let description = UTType(filenameExtension: ext)?.localizedDescription, !description.isEmpty else {
            return ext.uppercased() + " File"
        }
        return description.prefix(1).uppercased() + description.dropFirst()
    }
}

/// Finder icons, one per file type, made once.
enum FileIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func icon(for item: NodeItem) -> NSImage {
        icon(extension: item.fileExtension, isFolder: item.isFolder)
    }

    static func icon(name: String, isFolder: Bool) -> NSImage {
        icon(extension: (name as NSString).pathExtension.lowercased(), isFolder: isFolder)
    }

    private static func icon(extension ext: String, isFolder: Bool) -> NSImage {
        let key = isFolder ? "/folder" : ext
        if let icon = cache.object(forKey: key as NSString) { return icon }
        let type: UTType = isFolder ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        cache.setObject(icon, forKey: key as NSString)
        return icon
    }
}

nonisolated enum NodeLabel: Int, CaseIterable, Sendable {
    case none = 0, red, orange, yellow, green, blue, purple, grey

    var title: String {
        switch self {
        case .none: "None"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .grey: "Grey"
        }
    }

    var color: NSColor {
        switch self {
        case .none: .clear
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .grey: .systemGray
        }
    }
}

nonisolated enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        bytesPerSecond > 0 ? "\(bytes(bytesPerSecond))/s" : "–"
    }

    static func date(_ date: Date) -> String {
        date == .distantPast ? "–" : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Length of a video or audio file, as a player shows it: 4:05, 1:02:03.
    static func playtime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "–" }
        let time = Duration.seconds(Int(seconds.rounded(.down)))
        return time.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "–" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "–"
    }
}
