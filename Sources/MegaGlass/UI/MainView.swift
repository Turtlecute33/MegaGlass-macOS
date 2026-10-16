import SwiftUI
@preconcurrency import MEGASdk
import MEGABridge

enum SidebarItem: Hashable {
    case cloudDrive, recents, favourites, backups, rubbish
    case incoming, outgoing, links
    case openLink(UUID)
    case bypass
    case transfers, sync, contacts, account
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: SidebarItem? = .cloudDrive
    @State private var browser: BrowserModel?
    @State private var preparingBrowser = false
    /// A "Show in MEGA" folder that the Cloud Drive opens instead of its root.
    @State private var pendingReveal: UInt64?
    #if MEGAGLASS_TESTS
    @State private var resolvingTestFolder = false
    #endif

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .onAppear(perform: prepare)
        #if MEGAGLASS_TESTS
        .modifier(TestDriver(browser: browser))
        #endif
        .onChange(of: app.session.isSignedIn) { prepare() }
        .onChange(of: selection) { _, item in route(item) }
        .onChange(of: app.revealRequest) { _, handle in
            guard let handle, let browser else { return }
            if selection == .cloudDrive {
                browser.go(to: .folder(handle))
            } else {
                pendingReveal = handle
                selection = .cloudDrive
            }
            app.revealRequest = nil
        }
        // Requests can come before this window opens (a link from another app while the
        // window is closed, or while the account loads): they apply when it appears.
        .onChange(of: app.linkToShow, initial: true) { _, id in
            guard let id else { return }
            selection = .openLink(id)
            app.linkToShow = nil
        }
        .onChange(of: app.bypassRequested, initial: true) { _, requested in
            guard requested else { return }
            selection = .bypass
            app.bypassRequested = false
        }
        .onChange(of: app.transfersRequested, initial: true) { _, requested in
            guard requested else { return }
            selection = .transfers
            app.transfersRequested = false
        }
        .onChange(of: app.links.sessions.map(\.id)) { _, ids in
            if case let .openLink(id) = selection, !ids.contains(id) {
                selection = app.session.isSignedIn ? .cloudDrive : ids.last.map { .openLink($0) }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .openLink(let id):
            if let session = app.links.session(id) {
                LinkDetailView(session: session)
            } else {
                ContentUnavailableView("Link Closed", systemImage: "link")
            }
        case .bypass:
            BypassView()
        case .transfers:
            TransfersView()
        case .sync:
            SyncView()
        case .contacts:
            ContactsView()
        case .account:
            AccountView()
        case .none:
            GuestWelcome()
        default:
            if let browser, app.session.isSignedIn {
                BrowserView(model: browser)
                    .id(browser.engine.id)
            } else {
                GuestWelcome()
            }
        }
    }

    private func prepare() {
        guard app.session.isSignedIn else {
            browser?.stop()
            browser = nil
            if case .openLink = selection {} else {
                selection = app.links.sessions.last.map { .openLink($0.id) }
            }
            return
        }
        #if MEGAGLASS_TESTS
        guard browser == nil, !resolvingTestFolder else { return }
        resolvingTestFolder = true
        Task {
            if let handle = await TestRun.resolveFolder(app.engine.sdk) {
                browser = BrowserModel(engine: app.engine, start: .folder(handle))
            } else {
                TestRun.log("FAIL test folder not found")
                NSApp.terminate(nil)
            }
        }
        #else
        guard browser == nil, !preparingBrowser else { return }
        preparingBrowser = true
        let sdk = app.engine.sdk
        let generation = app.session.generation
        Task {
            defer { preparingBrowser = false }
            // The root node takes the engine lock: not on the main thread.
            let root = await EngineQueue.run { sdk.rootNode?.handle }
            guard browser == nil, app.session.isSignedIn, generation == app.session.generation, let root else { return }
            browser = BrowserModel(engine: app.engine, start: .folder(root))
            if selection == nil { selection = .cloudDrive }
        }
        #endif
    }

    private func route(_ item: SidebarItem?) {
        guard let browser, let item else { return }
        if item == .cloudDrive, let handle = pendingReveal {
            pendingReveal = nil
            browser.reset(to: .folder(handle))
            return
        }
        let sdk = app.engine.sdk
        let special: (@Sendable () -> MEGANode?)? = switch item {
        case .cloudDrive: { sdk.rootNode }
        case .backups: { sdk.vaultNode }
        case .rubbish: { sdk.rubbishNode }
        default: nil
        }
        if let special {
            // These nodes take the engine lock: not on the main thread.
            Task {
                guard let handle = await EngineQueue.run({ special()?.handle }), selection == item else { return }
                browser.reset(to: .folder(handle))
            }
            return
        }
        let target: Location? = switch item {
        case .recents: .recents
        case .favourites: .favourites
        case .incoming: .incomingShares
        case .outgoing: .outgoingShares
        case .links: .publicLinks
        default: nil
        }
        if let target { browser.reset(to: target) }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: SidebarItem?
    @State private var confirmCloseAll = false

    var body: some View {
        List(selection: $selection) {
            if app.session.isSignedIn {
                Section("MEGA") {
                    Label("Cloud Drive", systemImage: "cloud").tag(SidebarItem.cloudDrive)
                    Label("Recents", systemImage: "clock").tag(SidebarItem.recents)
                    Label("Favourites", systemImage: "heart").tag(SidebarItem.favourites)
                    Label("Backups", systemImage: "externaldrive.badge.timemachine").tag(SidebarItem.backups)
                    Label("Rubbish Bin", systemImage: "trash").tag(SidebarItem.rubbish)
                }
                Section("Shared") {
                    Label("Incoming Shares", systemImage: "person.2").tag(SidebarItem.incoming)
                    Label("Outgoing Shares", systemImage: "person.2.badge.gearshape").tag(SidebarItem.outgoing)
                    Label("Links", systemImage: "link").tag(SidebarItem.links)
                }
            }

            Section {
                ForEach(app.links.sessions) { session in
                    LinkSidebarRow(session: session, closeAll: { confirmCloseAll = true })
                        .tag(SidebarItem.openLink(session.id))
                }
                Label("Bypass", systemImage: "wand.and.sparkles")
                    .badge(app.bypass.jobs.filter { !$0.isFinished }.count)
                    .tag(SidebarItem.bypass)
                Button {
                    app.showOpenLinks = true
                } label: {
                    Label("Open Links…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                Text("Open Links")
            }

            Section("Activity") {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
                    .badge(app.transfers.activeCount)
                    .tag(SidebarItem.transfers)
                if app.session.isSignedIn {
                    Label {
                        Text("Sync & Backup")
                    } icon: {
                        Image(systemName: app.syncs.stoppedCount > 0 || app.syncs.isStalled ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, isActive: app.syncs.isSyncing)
                    }
                    .tag(SidebarItem.sync)
                    Label("Contacts", systemImage: "person.crop.circle").tag(SidebarItem.contacts)
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            let web = urls.filter { !$0.isFileURL }
            guard !web.isEmpty else { return false }
            app.handleIncoming(web.map(\.absoluteString).joined(separator: "\n"), source: .drop)
            return true
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter(selection: $selection)
        }
        .confirmationDialog("Close all \(app.links.sessions.count) open links?", isPresented: $confirmCloseAll) {
            Button("Close All Links", role: .destructive) { app.links.closeAll() }
        } message: {
            Text("The links, and their cache and thumbnails on this Mac, are removed. Copy the links that you want to keep first.")
        }
    }
}

private struct LinkSidebarRow: View {
    @Environment(AppModel.self) private var app
    let session: LinkSession
    let closeAll: () -> Void

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(session.title).lineLimit(1)
                Spacer(minLength: 0)
                if let size = session.totalSize {
                    SizeTag(bytes: size)
                        .help(session.kind == .folder ? "Size of the folder with all its subfolders" : "Size of the file")
                }
            }
        } icon: {
            if session.state == .opening {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: session.symbol)
            }
        }
        .contextMenu {
            Button("Copy Link") {
                Pasteboard.copy(session.link)
            }
            Button("Close Link", role: .destructive) { app.links.close(session) }
            Button("Close All Links…", role: .destructive, action: closeAll)
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: SidebarItem?

    var body: some View {
        #if MEGAGLASS_TESTS
        EmptyView()
        #else
        content
        #endif
    }

    private var content: some View {
        Group {
            if app.session.isSignedIn {
                Button {
                    selection = .account
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(app.session.displayName ?? app.session.email ?? "Account")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(app.session.account?.plan ?? "")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.megaRed.opacity(0.18), in: .capsule)
                        }
                        if let account = app.session.account {
                            UsageBar(fraction: account.storageFraction)
                            Text("\(Format.bytes(account.storageUsed)) of \(Format.bytes(account.storageMax))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassPanel(cornerRadius: 16)
            } else {
                Button {
                    app.session.isGuest = false
                } label: {
                    Label("Log In to MEGA", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(10)
    }
}

private struct GuestWelcome: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("Open MEGA Links", systemImage: "link")
        } description: {
            Text("Paste file or folder links to browse, preview and download them. You can open many links at the same time.")
        } actions: {
            Button("Open Links…") { app.showOpenLinks = true }
                .buttonStyle(.glassProminent)
        }
    }
}
