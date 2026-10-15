import SwiftUI

@main
struct MegaGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The delegate owns the model, so links that start the app arrive before any window.
    private var app: AppModel { delegate.app }

    var body: some Scene {
        WindowGroup(id: "main") {
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
    let app = AppModel()

    /// Links from other apps and the browser router:
    /// - mega://… (like magnet links for a torrent app)
    /// - http(s) links when MegaGlass is the default browser: MEGA and protector links
    ///   stay here, every other link goes on to the real browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        var forward: [URL] = []
        for url in urls {
            switch url.scheme?.lowercased() {
            case "mega":
                app.handleIncoming(url.absoluteString, source: .scheme)
            case "http", "https":
                let sorted = LinkSorter.sort(url.absoluteString, protectorHosts: Set(app.settings.protectorHosts))
                if sorted.isEmpty {
                    forward.append(url)
                } else {
                    app.handleIncoming(url.absoluteString, source: .scheme)
                }
            default:
                // Web pages and files: the real browser opens them.
                forward.append(url)
            }
        }
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

}

struct AppCommands: Commands {
    let app: AppModel
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("New Folder…") { browser?.newFolderRequested = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.canWrite != true)
            Button("Upload Files…") {
                if let folder = browser?.currentFolder { app.chooseAndUpload(to: folder, folders: false) }
            }
            .keyboardShortcut("u")
            .disabled(browser?.canWrite != true || browser?.engine.kind != .account)
            Button("Upload Folder…") {
                if let folder = browser?.currentFolder { app.chooseAndUpload(to: folder, folders: true) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(browser?.canWrite != true || browser?.engine.kind != .account)
            Divider()
            Button("Open Links…") { app.showOpenLinks = true }
                .keyboardShortcut("l")
            Button("Open Links from Clipboard") {
                if let text = NSPasteboard.general.string(forType: .string) { app.handleIncoming(text, source: .paste) }
            }
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
}
