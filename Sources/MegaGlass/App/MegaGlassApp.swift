import SwiftUI

@main
struct MegaGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The delegate owns the model, so links that start the app arrive before any window.
    private var app: AppModel { delegate.app }

    var body: some Scene {
        // One main window: opening it again brings it to the front.
        Window("MegaGlass", id: "main") {
            RootView()
                .environment(app)
                .task { await app.startOnce() }
        }
        .defaultSize(width: 1180, height: 760)
        .handlesExternalEvents(matching: [])
        .commands { AppCommands(app: app) }

        WindowGroup("Preview", id: "preview", for: PreviewRequest.self) { $request in
            PreviewView(request: request)
                .environment(app)
                .tint(.megaRed)
        }
        .defaultSize(width: 960, height: 680)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(app)
        }

        MenuBarExtra(isInserted: Binding(get: { app.settings.showMenuBarExtra },
                                         set: { app.settings.showMenuBarExtra = $0 })) {
            MenuBarView()
                .environment(app)
        } label: {
            MenuBarIcon(app: app)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let app: AppModel

    override init() {
        // Before the model: it starts the engine and cleans the caches.
        InstanceLock.acquireOrQuit()
        Self.raiseFileLimit()
        app = AppModel()
        super.init()
    }

    /// Links from other apps and the browser router:
    /// - mega://… (like magnet links for a torrent app)
    /// - http(s) links when MegaGlass is the default browser: MEGA and protector links
    ///   stay here, every other link goes on to the real browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        var forward: [URL] = []
        // All the links of one event together: many links ask first.
        var incoming = LinkSorter.Result()
        var empty = false
        for url in urls {
            let sorted = LinkSorter.incoming(url, protectorHosts: Set(app.settings.protectorHosts))
            switch url.scheme?.lowercased() {
            case "mega":
                if sorted.isEmpty { empty = true }
                incoming.add(sorted)
            case "http", "https":
                if sorted.isEmpty {
                    forward.append(url)
                } else {
                    incoming.add(sorted)
                }
            default:
                // Web pages and files: the real browser opens them.
                forward.append(url)
            }
        }
        if !incoming.isEmpty || empty { app.receiveFromOtherApp(incoming) }
        BrowserRouter.forward(forward, settings: app.settings)
    }

    /// The session and the saved links start with the app, also when macOS restores only a
    /// preview window or the menu bar item (the main window also calls this; it runs once).
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await app.startOnce() }
    }

    /// Syncs and transfers go on after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard app.transfers.hasActivity || app.syncs.isSyncing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with active transfers or syncs?"
        alert.informativeText = "Transfers and syncs stop when MegaGlass quits. Files already transferred are kept."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.shutdown()
    }

    /// Each engine (the account and each open folder link) keeps files and connections open:
    /// the soft limit of 256 is too low. The SDK waits with poll(), which has no FD_SETSIZE limit.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, 4096)
        guard limit.rlim_cur < wanted else { return }
        limit.rlim_cur = wanted
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}

/// One MegaGlass at a time. A second copy (another path, or `open -n`) would run a second
/// engine on the same account folder, databases and caches.
enum InstanceLock {
    /// Stays open while the app runs; the system releases the lock when the process ends.
    private static var descriptor: Int32 = -1

    static func acquireOrQuit() {
        let file = AppPaths.ensure(AppPaths.support).appending(path: ".instance.lock")
        let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            return
        }
        let held = errno == EWOULDBLOCK
        close(fd)
        guard held else { return }
        // The copy that runs comes to the front, and this one quits before it touches any
        // data. Links that started this copy are lost: they arrive only after the launch.
        let pid = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleID)
            .first(where: { $0.processIdentifier != pid }) {
            if let bundle = other.bundleURL, bundle != Bundle.main.bundleURL {
                // As a click on its Dock icon: it also opens its main window.
                NSWorkspace.shared.open(bundle)
            } else {
                other.activate()
            }
        }
        exit(0)
    }
}

struct AppCommands: Commands {
    let app: AppModel
    @FocusedValue(\.browser) private var browser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The menus live as long as the app: links that arrive with no window open it with this.
        let _ = app.openMainWindow = { [openWindow] in openWindow(id: "main") }
        CommandGroup(after: .newItem) {
            Divider()
            Button("New Folder…") { browser?.newFolderRequested = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.canUpload != true)
            Button("Upload Files…") { upload(folders: false) }
                .keyboardShortcut("u")
                .disabled(browser?.canUpload != true)
            Button("Upload Folder…") { upload(folders: true) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(browser?.canUpload != true)
            Divider()
            Button("Open Links…") { app.showOpenLinks = true }
                .keyboardShortcut("l")
            Button("Open Links from Clipboard") { app.openLinksFromClipboard() }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[")
                .disabled(browser?.canGoBack != true)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]")
                .disabled(browser?.canGoForward != true)
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(browser?.canGoUp != true)
            Divider()
            Button("Reload") { browser?.reload() }
                .keyboardShortcut("r")
        }

        CommandGroup(before: .toolbar) {
            Button("as List") { app.settings.viewMode = .list }
                .keyboardShortcut("1")
            Button("as Grid") { app.settings.viewMode = .grid }
                .keyboardShortcut("2")
            Button(app.settings.showInspector ? "Hide Inspector" : "Show Inspector") { app.settings.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Button(app.transfers.isPaused ? "Resume All Transfers" : "Pause All Transfers") { app.transfers.togglePauseAll() }
        }
    }

    private func upload(folders: Bool) {
        guard let browser, browser.canUpload, let folder = browser.currentFolder else { return }
        app.chooseAndUpload(to: folder, folders: folders)
    }
}
