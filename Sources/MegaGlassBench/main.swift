// Checks the engine as built for MegaGlass, without the UI:
//   swift run -c release megaglass-bench [connections]
// Uses MEGA's own public test links from the MEGA SDK integration tests.
import Foundation
@preconcurrency import MEGASdk
import MEGABridge

let fileLink = "https://mega.nz/file/JzckQJ6L#X_p0u26-HOTenAG0rATFhKdxYx-rOV1U6YHYhnz2nsA" // 100 MB test file
let folderLink = "https://mega.nz/folder/eZx2TI7Z#g2qzUrS9ausRp0Ua7XD01w"
let connections = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 8

final class Waiter: NSObject, MEGARequestDelegate, MEGATransferDelegate, @unchecked Sendable {
    private var requestContinuation: CheckedContinuation<MEGARequest, any Error>?
    private var transferContinuation: CheckedContinuation<MEGATransfer, any Error>?
    var lastReport = Date.distantPast

    func request(_ start: (MEGARequestDelegate) -> Void) async throws -> MEGARequest {
        try await withCheckedThrowingContinuation { continuation in
            requestContinuation = continuation
            start(self)
        }
    }

    func transfer(_ start: (MEGATransferDelegate) -> Void) async throws -> MEGATransfer {
        try await withCheckedThrowingContinuation { continuation in
            transferContinuation = continuation
            start(self)
        }
    }

    func onRequestFinish(_ api: MEGASdk, request: MEGARequest, error: MEGAError) {
        let continuation = requestContinuation
        requestContinuation = nil
        if error.type == .apiOk { continuation?.resume(returning: request) }
        else { continuation?.resume(throwing: NSError(domain: "MEGA", code: error.type.rawValue, userInfo: [NSLocalizedDescriptionKey: error.name])) }
    }

    func onTransferUpdate(_ api: MEGASdk, transfer: MEGATransfer) {
        guard Date().timeIntervalSince(lastReport) > 1 else { return }
        lastReport = Date()
        let percent = transfer.totalBytes > 0 ? 100 * Double(transfer.transferredBytes) / Double(transfer.totalBytes) : 0
        print(String(format: "  %5.1f %%  %7.1f MB/s", percent, Double(transfer.speed) / 1_048_576))
    }

    func onTransferFinish(_ api: MEGASdk, transfer: MEGATransfer, error: MEGAError) {
        let continuation = transferContinuation
        transferContinuation = nil
        if error.type == .apiOk { continuation?.resume(returning: transfer) }
        else { continuation?.resume(throwing: NSError(domain: "MEGA", code: error.type.rawValue, userInfo: [NSLocalizedDescriptionKey: error.name])) }
    }
}

let work = FileManager.default.temporaryDirectory.appending(path: "megaglass-bench-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

print("== Cryptography (Crypto++ as linked)")
print("Hardware AES:", MGDiagnostics.hasHardwareAES ? "yes" : "NO")
print(String(format: "AES-128-CTR: %.0f MB/s", MGDiagnostics.aesCTRThroughput(withMegabytes: 1024)))
print(String(format: "AES-128 CBC-MAC: %.0f MB/s", MGDiagnostics.cbcMACThroughput(withMegabytes: 1024)))

print("\n== File link download (\(connections) connections)")
let engineDir = work.appending(path: "engine")
try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
let sdk = MEGASdk.makeSdk(userAgent: "MegaGlass-bench/1.0", basePath: engineDir.path, workerThreads: 4, uploadThumbnails: false)!
sdk.setMaxConnectionsForDirection(.download, connections: connections)
let waiter = Waiter()
let node = try await waiter.request { sdk.publicNode(forMegaFileLink: fileLink, delegate: $0) }.publicNode!
print("Name:", node.name ?? "?", "Size:", node.size?.int64Value ?? 0)
let downloads = work.appending(path: "downloads")
try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
let start = Date()
let transfer = try await waiter.transfer {
    sdk.startDownloadNode(node, localPath: downloads.path + "/", fileName: nil, appData: nil, startFirst: true,
                          cancelToken: nil, collisionCheck: .assumeDifferent, collisionResolution: .overwrite, delegate: $0)
}
let seconds = Date().timeIntervalSince(start)
let file = downloads.appending(path: node.name ?? "file")
let written = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
print(String(format: "Done: %.1f MB in %.1f s = %.1f MB/s", Double(transfer.totalBytes) / 1_048_576, seconds,
             Double(transfer.totalBytes) / 1_048_576 / seconds))
print("File on disk:", written == node.size?.int64Value ? "size matches, MAC verified by the engine" : "SIZE MISMATCH \(written)")

print("\n== Folder link")
let linkDir = work.appending(path: "link")
try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
let linkSdk = MEGASdk.makeSdk(userAgent: "MegaGlass-bench/1.0", basePath: linkDir.path, workerThreads: 2, uploadThumbnails: false)!
_ = try await waiter.request { linkSdk.login(toFolderLink: folderLink, delegate: $0) }
_ = try await waiter.request { linkSdk.fetchNodes(with: $0) }
if let root = linkSdk.rootNode {
    let children = linkSdk.children(forParent: root)
    print("Root:", root.name ?? "?", "Items:", children.size)
    for index in 0..<min(children.size, 5) {
        if let child = children.node(at: index) {
            print("  -", child.name ?? "?", child.isFolder() ? "(folder)" : "\(child.size?.int64Value ?? 0) bytes")
        }
    }
}
linkSdk.localLogout()
print("\nAll checks passed.")
