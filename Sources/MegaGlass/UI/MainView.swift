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
            selection = .cloudDrive
            browser.go(to: .folder(handle))
            app.revealRequest = nil
        }
        .onChange(of: app.linkToShow) { _, id in
            guard let id else { return }
            selection = .openLink(id)
            app.linkToShow = nil
        }
        .onChange(of: app.bypassRequested) { _, requested in
            guard requested else { return }
            selection = .bypass
            app.bypassRequested = false
        }
        .onChange(of: app.transfersRequested) { _, requested in
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
        if browser == nil, let root = app.engine.sdk.rootNode {
            browser = BrowserModel(engine: app.engine, start: .folder(root.handle))
            if selection == nil { selection = .cloudDrive }
        }
        #endif
    }

    private func route(_ item: SidebarItem?) {
        guard let browser, let item else { return }
        let sdk = app.engine.sdk
        let target: Location? = switch item {
        case .cloudDrive: sdk.rootNode.map { .folder($0.handle) }
        case .backups: sdk.vaultNode.map { .folder($0.handle) }
        case .rubbish: sdk.rubbishNode.map { .folder($0.handle) }
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
                    LinkSidebarRow(session: session)
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
                        Image(systemName: app.syncs.isStalled ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
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
    }
}

private struct LinkSidebarRow: View {
    @Environment(AppModel.self) private var app
    let session: LinkSession

    var body: some View {
        Label {
            Text(session.title).lineLimit(1)
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
