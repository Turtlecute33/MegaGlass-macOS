#if MEGAGLASS_TESTS
// Test builds only (swift build -Xswiftc -DMEGAGLASS_TESTS). Never part of the app.
// Opens one folder of the account, previews one file of each kind, saves window
// images and a log, then quits. Read-only: nothing in the account changes.
import AppKit
@preconcurrency import MEGASdk
import SwiftUI

enum TestRun {
    private static let environment = ProcessInfo.processInfo.environment
    static let folder = environment["MEGAGLASS_TEST_FOLDER"]
    static let output = environment["MEGAGLASS_TEST_OUTPUT"].map { URL(filePath: $0) }

    static func log(_ text: String) {
        guard let output else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(text)\n"
        let file = output.appending(path: "test.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// Finds the test folder. Names are compared in code; the log shows only
    /// which method found it, never any names.
    static func resolveFolder(_ sdk: MEGASdk) async -> UInt64? {
        guard let path = folder else { return nil }
        let name = (path as NSString).lastPathComponent
        for attempt in 1...10 {
            let result = await EngineQueue.run { () -> (UInt64?, String) in
                if let node = sdk.node(forPath: path) { return (node.handle, "found by path") }
                guard let root = sdk.rootNode else { return (nil, "no root node") }
                let children = sdk.nodes(sdk.children(forParent: root))
                if let match = children.first(where: { $0.isFolder() && $0.name == name }) {
                    return (match.handle, "found by child scan (path lookup failed)")
                }
                let near = children.contains {
                    $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name.lowercased()
                }
                return (nil, near ? "near match only (case or spaces differ)" : "no match")
            }
            log("lookup \(attempt): \(result.1)")
            if let handle = result.0 { return handle }
            try? await Task.sleep(for: .seconds(3))
        }
        return nil
    }

    /// Logs the table views of the main window (the sidebar is one), with their row counts.
    static func describeTables() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let root = window.contentView?.superview else { return }
        var tables: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            view.subviews.forEach(walk)
        }
        walk(root)
        for table in tables {
            let frame = table.convert(table.bounds, to: nil)
            log("table \(String(describing: type(of: table))): rows \(table.numberOfRows), x \(Int(frame.minX)), width \(Int(frame.width)), hidden \(table.isHiddenOrHasHiddenAncestor)")
        }
    }

    static func snapshot(_ label: String) {
        guard let output else { return }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: output.appending(path: "\(label)-\(index).png"))
        }
    }
}

struct TestDriver: ViewModifier {
    let browser: BrowserModel?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.task(id: browser?.engine.id) { await run() }
    }

    private func run() async {
        guard app.session.isSignedIn, let browser else { return }
        TestRun.log("start")
        for _ in 0..<120 where browser.isLoading {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let items = browser.items
        TestRun.log("listing: \(items.count) items, kinds: \(items.map(\.kind.rawValue).joined(separator: ","))")
        try? await Task.sleep(for: .seconds(4))
        TestRun.describeTables()
        TestRun.snapshot("01-list")

        app.settings.viewMode = .grid
        try? await Task.sleep(for: .seconds(4))
        TestRun.snapshot("02-grid")
        app.settings.viewMode = .list

        if let first = items.first(where: { !$0.isFolder }) {
            browser.selection = [first.id]
            app.settings.showInspector = true
            try? await Task.sleep(for: .seconds(4))
            TestRun.snapshot("03-inspector")
            app.settings.showInspector = false
            browser.selection = []
        }

        var kinds = Set<FileKind>()
        var step = 4
        for item in items where !item.isFolder && kinds.insert(item.kind).inserted {
            let request = PreviewRequest(engineID: browser.engine.id, handle: item.id)
            TestRun.log("preview open: \(item.kind.rawValue), \(Format.bytes(item.size)), thumbnail \(item.hasThumbnail), preview \(item.hasPreview)")
            openWindow(id: "preview", value: request)
            try? await Task.sleep(for: .seconds(14))
            TestRun.snapshot(String(format: "%02d-preview-%@", step, item.kind.rawValue))
            step += 1
            dismissWindow(id: "preview", value: request)
            try? await Task.sleep(for: .seconds(2))
            TestRun.log("preview closed: \(item.kind.rawValue)")
        }
        TestRun.log("done")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }
}
#endif
