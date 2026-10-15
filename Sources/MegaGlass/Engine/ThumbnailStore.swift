import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import MEGASdk

/// Thumbnails (240 px) and previews (1000 px) that MEGA stores encrypted next to each file.
/// Two cache levels: decoded images in memory, decrypted JPEG files on disk.
/// Requests for the same image share one download.
nonisolated final class ThumbnailStore: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let sdk: MEGASdk
    private final class Generation: @unchecked Sendable {
        let id: UUID
        let directory: URL
        private let lock = NSLock()
        private var retired = false
        init(root: URL, id: UUID = UUID()) {
            self.id = id
            directory = AppPaths.ensure(root.appending(path: id.uuidString))
        }
        func retire() { lock.withLock { retired = true } }
        deinit {
            if retired {
                let directory = directory
                DispatchQueue.global(qos: .utility).async { AppPaths.removeAll(at: directory) }
            }
        }
    }
    private struct Entry {
        let id = UUID()
        let task: Task<CGImage?, Never>
    }
    private let directory: URL
    private let fetchAttribute: (@Sendable (UInt64, MEGANode?, Bool, URL) async throws -> Void)?
    private var generation: Generation
    private let memory = NSCache<NSNumber, Box>()
    private let lock = NSLock()
    private var inflight: [String: Entry] = [:]

    init(sdk: MEGASdk, directory: URL,
         fetchAttribute: (@Sendable (UInt64, MEGANode?, Bool, URL) async throws -> Void)? = nil) {
        self.sdk = sdk
        self.directory = AppPaths.ensure(directory)
        self.fetchAttribute = fetchAttribute
        let marker = directory.appending(path: "generation")
        let saved = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(UUID.init(uuidString:))
        let current = Generation(root: directory, id: saved ?? UUID())
        generation = current
        try? Data(current.id.uuidString.utf8).write(to: marker, options: .atomic)
        // Only one store owns each engine scope. Remove crash leftovers and the old
        // pre-generation cache before any new SDK attribute writers are started.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent != current.id.uuidString && file.lastPathComponent != "generation" {
            AppPaths.removeAll(at: file)
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: current.directory, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "partial" { AppPaths.removeAll(at: file) }
        memory.countLimit = 1000
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    /// Synchronous memory lookup, so a cell can draw a known thumbnail in its first frame.
    func cached(_ handle: UInt64) -> CGImage? {
        memory.object(forKey: NSNumber(value: handle))?.image
    }

    @concurrent func thumbnail(_ handle: UInt64, node: MEGANode? = nil) async -> CGImage? {
        if let image = cached(handle) { return image }
        return await load(handle, node: node, preview: false)
    }

    @concurrent func preview(_ handle: UInt64, node: MEGANode? = nil) async -> CGImage? {
        await load(handle, node: node, preview: true)
    }

    func clear() {
        let next = Generation(root: directory)
        try? Data(next.id.uuidString.utf8).write(to: directory.appending(path: "generation"), options: .atomic)
        let old = lock.withLock {
            memory.removeAllObjects()
            let old = generation
            generation = next
            return old
        }
        old.retire()
        // Old generations stay alive until their SDK writes finish, then remove themselves.
    }

    private func load(_ handle: UInt64, node: MEGANode?, preview: Bool) async -> CGImage? {
        let key = (preview ? "p" : "t") + String(handle, radix: 16)
        let (cacheKey, entry) = lock.withLock { () -> (String, Entry) in
            let current = generation
            let cacheKey = current.id.uuidString + key
            if let running = inflight[cacheKey] { return (cacheKey, running) }
            let entry = Entry(task: Task.detached(priority: .utility) { [self, current] in
                await fetch(handle, key: key, node: node, preview: preview, generation: current)
            })
            inflight[cacheKey] = entry
            return (cacheKey, entry)
        }
        let image = await entry.task.value
        let current = lock.withLock {
            if inflight[cacheKey]?.id == entry.id { inflight[cacheKey] = nil }
            return cacheKey.hasPrefix(generation.id.uuidString)
        }
        return Task.isCancelled || !current ? nil : image
    }

    private func fetch(_ handle: UInt64, key: String, node: MEGANode?, preview: Bool, generation: Generation) async -> CGImage? {
        let file = generation.directory.appending(path: key + ".jpg")
        if FileManager.default.fileExists(atPath: file.path),
           let image = Self.decode(file, maxPixelSize: preview ? 2048 : 480) {
            return lock.withLock {
                guard generation === self.generation else { return nil }
                if !preview { memory.setObject(Box(image), forKey: NSNumber(value: handle), cost: image.bytesPerRow * image.height) }
                return image
            }
        }
        let staging = generation.directory.appending(path: UUID().uuidString + ".partial")
        let sdk = self.sdk
        do {
            if let fetchAttribute {
                try await fetchAttribute(handle, node, preview, staging)
            } else {
                guard let node = node ?? sdk.node(forHandle: handle) else { return nil }
                _ = try await sdk.request { delegate in
                    if preview {
                        sdk.getPreviewNode(node, destinationFilePath: staging.path, delegate: delegate)
                    } else {
                        sdk.getThumbnailNode(node, destinationFilePath: staging.path, delegate: delegate)
                    }
                }
            }
            // Publish a disk-cache entry only after SDK success. A crash or a failed
            // attribute download leaves a staging file that is never used as a cache hit.
            AppPaths.removeAll(at: file)
            try FileManager.default.moveItem(at: staging, to: file)
        } catch {
            AppPaths.removeAll(at: staging)
            return nil
        }
        guard let image = Self.decode(file, maxPixelSize: preview ? 2048 : 480) else {
            AppPaths.removeAll(at: file)
            return nil
        }
        return lock.withLock {
            guard generation === self.generation else { return nil }
            if !preview {
                memory.setObject(Box(image), forKey: NSNumber(value: handle), cost: image.bytesPerRow * image.height)
            }
            return image
        }
    }

    /// Decodes now (not at first draw), so the main thread never decodes JPEG data.
    static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
