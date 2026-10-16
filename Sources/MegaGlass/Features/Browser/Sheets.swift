import SwiftUI
@preconcurrency import MEGASdk
import MEGABridge

struct NameSheet: View {
    let title: String
    let action: String
    let initial: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(done)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty || trimmed.contains("/"))
            }
        }
        .padding(22)
        .onAppear {
            name = initial
            focused = true
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func done() {
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        commit(trimmed)
        dismiss()
    }
}

/// Picks a folder in the account Cloud Drive.
struct FolderPicker: View {
    let title: String
    let action: String
    let exclude: Set<UInt64>
    let choose: (UInt64) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: [NodeItem] = []
    @State private var folders: [NodeItem] = []
    @State private var selection: UInt64?
    @State private var newFolder = false
    @State private var loadRevision = 0
    /// The folder that `folders` lists.
    @State private var loadedParent: UInt64?
    /// Read once, off the main thread (the engine lock).
    @State private var rootHandle: UInt64?

    private var current: UInt64? { path.last?.id ?? rootHandle }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(spacing: 4) {
                Button("Cloud Drive") { path.removeAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(path.isEmpty ? .primary : .secondary)
                ForEach(path) { folder in
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    Button(folder.name) {
                        if let index = path.firstIndex(of: folder) { path.removeSubrange((index + 1)...) }
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                }
            }
            .font(.callout)

            List(folders, selection: $selection) { folder in
                Label {
                    Text(folder.name)
                } icon: {
                    Image(nsImage: FileIcons.icon(for: folder)).resizable().frame(width: 18, height: 18)
                }
                .tag(folder.id)
                .disabled(exclude.contains(folder.id))
                .onTapGesture(count: 2) {
                    guard !exclude.contains(folder.id) else { return }
                    path.append(folder)
                }
            }
            .frame(width: 440, height: 300)
            .overlay {
                if folders.isEmpty {
                    Text("No subfolders").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("New Folder…") { newFolder = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection == nil ? "\(action) Here" : action) {
                    if let target = selection ?? current, !exclude.contains(target) {
                        choose(target)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .task(id: path.last?.id) { await load() }
        .onChange(of: app.engine.nodeChange) { Task { await load() } }
        .sheet(isPresented: $newFolder) {
            NameSheet(title: "New Folder", action: "Create", initial: "New Folder") { name in
                guard let current else { return }
                Task { await app.createFolder(named: name, in: current, engine: app.engine) }
            }
        }
    }

    private func load() async {
        loadRevision += 1
        let revision = loadRevision
        let sdk = app.engine.sdk
        if rootHandle == nil {
            rootHandle = await EngineQueue.run { sdk.rootNode?.handle }
            guard revision == loadRevision else { return }
        }
        let parent = current
        // A new folder clears the selection; a refresh of the same folder keeps it.
        if parent != loadedParent { selection = nil }
        let result: [NodeItem] = await EngineQueue.run {
            guard let parent, let node = sdk.node(forHandle: parent) else { return [] }
            return sdk.nodes(sdk.children(forParent: node, order: MEGASortOrderType.defaultAsc.rawValue))
                .filter { $0.isFolder() }
                .map { NodeItem($0) }
        }
        guard !Task.isCancelled, revision == loadRevision, parent == current else { return }
        folders = result
        loadedParent = parent
        if let selected = selection, !result.contains(where: { $0.id == selected }) { selection = nil }
    }
}

struct ShareSheet: View {
    let item: NodeItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var access: MEGAShareType = .accessRead
    @State private var shares: [(email: String, access: MEGAShareType, pending: Bool)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share “\(item.name)”").font(.headline)
            Text("People you share with can see the folder with end-to-end encryption.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                Picker("Access", selection: $access) {
                    Text("Read only").tag(MEGAShareType.accessRead)
                    Text("Read and write").tag(MEGAShareType.accessReadWrite)
                    Text("Full access").tag(MEGAShareType.accessFull)
                }
                .labelsHidden()
                .frame(width: 150)
                Button("Share") {
                    let address = email.trimmingCharacters(in: .whitespaces)
                    Task {
                        await app.share(item.id, with: address, access: access)
                        email = ""
                        await load()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!email.contains("@"))
            }

            if !shares.isEmpty {
                List {
                    ForEach(shares, id: \.email) { share in
                        HStack {
                            Image(systemName: "person.crop.circle")
                            Text(share.email)
                            if share.pending {
                                Text("Pending").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.title(share.access)).foregroundStyle(.secondary)
                            Button {
                                Task {
                                    await app.share(item.id, with: share.email, access: .accessUnknown)
                                    await load()
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Remove access")
                        }
                    }
                }
                .frame(height: 160)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { await load() }
    }

    private func load() async {
        let sdk = app.engine.sdk
        let handle = item.id
        // The share list takes the engine lock: not on the main thread.
        shares = await EngineQueue.run {
            guard let node = sdk.node(forHandle: handle) else { return [] }
            let list = sdk.outShares(for: node)
            return (0..<list.size).compactMap { list.share(at: $0) }.compactMap { share in
                guard let user = share.user else { return nil }
                return (email: user, access: share.access, pending: share.isPending)
            }
        }
    }

    static func title(_ access: MEGAShareType) -> String {
        switch access {
        case .accessRead: "Read only"
        case .accessReadWrite: "Read and write"
        case .accessFull: "Full access"
        case .accessOwner: "Owner"
        default: "No access"
        }
    }
}

/// Makes a public link, with the options of the official apps.
struct LinkSheet: View {
    let items: [NodeItem]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var links: [String] = []
    @State private var separateKey = false
    @State private var useExpiry = false
    @State private var expiry = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var usePassword = false
    @State private var password = ""
    @State private var protected: [String] = []
    @State private var exporting = false
    @State private var exportRevision = 0
    @State private var busy = false

    private var isPaid: Bool { app.session.account?.isPaid == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? "Link to “\(items[0].name)”" : "Links to \(items.count) Items")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                    // Not selectable: only the Copy buttons keep the keys on this Mac and out of
                    // clipboard histories.
                    ForEach(display, id: \.self) { line in
                        Text(line)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Toggle("Send the decryption key separately", isOn: $separateKey)
                .disabled(usePassword)
            Toggle("Expiry date", isOn: $useExpiry)
                .disabled(!isPaid)
            if useExpiry {
                DatePicker("Expires", selection: $expiry, in: Date()..., displayedComponents: .date)
            }
            Toggle("Password protection", isOn: $usePassword)
                .disabled(!isPaid)
            if usePassword {
                HStack {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Button("Protect") { Task { await protect() } }
                        .disabled(password.count < 4 || busy || links.isEmpty)
                }
            }
            if !isPaid {
                Text("Expiry dates and passwords need a Pro account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                if separateKey, !usePassword {
                    // Two copies, so the key can go by another channel.
                    Button(links.count == 1 ? "Copy Key" : "Copy Keys") {
                        copy(LinkPresentation.keys(of: links), "Key copied")
                    }
                    .disabled(links.isEmpty || busy)
                }
                Button(separateKey && !usePassword ? (links.count == 1 ? "Copy Link" : "Copy Links") : "Copy") {
                    if separateKey, !usePassword {
                        copy(LinkPresentation.withoutKeys(links), "Link copied, without the key")
                    } else {
                        copy(display, "Copied")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(display.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { requestExport() }
        .onChange(of: useExpiry) { requestExport() }
        .onChange(of: expiry) { if useExpiry { requestExport() } }
        .onChange(of: password) { protected = [] }
        .onChange(of: usePassword) { protected = [] }
    }

    private var display: [String] {
        LinkPresentation.lines(links: links, protected: protected, usePassword: usePassword, separateKey: separateKey)
    }

    private func copy(_ lines: [String], _ message: String) {
        Pasteboard.copy(lines.joined(separator: "\n"))
        app.notify(message, symbol: "doc.on.doc")
    }

    private func requestExport() {
        exportRevision += 1
        protected = []
        links = []
        guard !exporting else { return }
        exporting = true
        busy = true
        // Serialize server mutations. Canceling the waiter cannot undo an export
        // already sent to MEGA, so drain the newest options after each confirmation.
        Task { await exportLatest() }
    }

    private func exportLatest() async {
        defer { exporting = false; busy = false }
        let sdk = app.engine.sdk
        let generation = app.session.generation
        while app.session.generation == generation, app.session.isSignedIn, !app.session.isSigningOut {
            let revision = exportRevision
            let date = useExpiry ? expiry : nil
            var result: [String] = []
            do {
                for item in items {
                    guard let node = await sdk.loadNode(item.id) else {
                        throw MegaFailure(code: -9, message: "The item is no longer available.")
                    }
                    let request = try await sdk.request { delegate in
                        if let date { sdk.export(node, expireTime: date, delegate: delegate) }
                        else { sdk.export(node, delegate: delegate) }
                    }
                    guard app.session.generation == generation, !app.session.isSigningOut else { return }
                    if revision != exportRevision { break }
                    if let link = request.link { result.append(link) }
                }
            } catch {
                if revision == exportRevision { app.show(error, title: "The link was not created"); return }
            }
            if revision == exportRevision { links = result; return }
        }
    }

    private func protect() async {
        guard !busy, usePassword, !links.isEmpty else { return }
        busy = true
        defer { if !exporting { busy = false } }
        let original = links
        let secret = password
        let revision = exportRevision
        var result: [String] = []
        for link in original {
            guard let value = await app.protectLink(link, password: secret) else { return }
            result.append(value)
        }
        guard usePassword, secret == password, revision == exportRevision else { return }
        protected = result
    }
}

nonisolated enum LinkPresentation {
    static func lines(links: [String], protected: [String], usePassword: Bool, separateKey: Bool) -> [String] {
        if usePassword { return protected }
        guard separateKey else { return links }
        return links.flatMap { link -> [String] in
            let parts = link.split(separator: "#", maxSplits: 1).map(String.init)
            return parts.count == 2 ? [parts[0], "Key: " + parts[1]] : [link]
        }
    }

    static func withoutKeys(_ links: [String]) -> [String] {
        links.map { String($0.split(separator: "#", maxSplits: 1).first ?? Substring($0)) }
    }

    static func keys(of links: [String]) -> [String] {
        links.compactMap { link in
            let parts = link.split(separator: "#", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        }
    }
}

struct VersionsSheet: View {
    let item: NodeItem
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [NodeItem] = []
    @State private var confirmDelete: NodeItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Versions of “\(item.name)”").font(.headline)
            List(Array(versions.enumerated()), id: \.element.id) { index, version in
                HStack {
                    VStack(alignment: .leading) {
                        Text(index == 0 ? "Current version" : Format.date(version.modified))
                            .font(.body.weight(index == 0 ? .semibold : .regular))
                        Text("\(Format.bytes(version.size)) · \(Format.date(version.created))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { app.download([version.id], from: app.engine) } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.plain)
                        .help("Download this version")
                    if index > 0 {
                        Button("Restore") { Task { await restore(version) } }
                        Button(role: .destructive) { confirmDelete = version } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .help("Delete this version")
                    }
                }
            }
            .frame(width: 480, height: 280)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .task { await load() }
        .confirmationDialog("Delete this version permanently?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { version in
            Button("Delete", role: .destructive) { Task { await delete(version) } }
        } message: { _ in
            Text("You cannot undo this.")
        }
    }

    private func load() async {
        let sdk = app.engine.sdk
        let handle = item.id
        versions = await EngineQueue.run {
            guard let node = sdk.node(forHandle: handle) else { return [] }
            return sdk.nodes(sdk.versions(for: node)).map { NodeItem($0) }
        }
    }

    private func restore(_ version: NodeItem) async {
        let sdk = app.engine.sdk
        guard let node = await sdk.loadNode(version.id) else { return }
        do {
            _ = try await sdk.request { sdk.restoreVersionNode(node, delegate: $0) }
            app.notify("Version restored", symbol: "clock.arrow.circlepath")
            dismiss()
        } catch {
            app.show(error, title: "The version was not restored")
        }
    }

    private func delete(_ version: NodeItem) async {
        await app.deletePermanently([version.id], engine: app.engine)
        await load()
    }
}
