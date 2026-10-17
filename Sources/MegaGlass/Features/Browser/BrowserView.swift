import SwiftUI
import UniformTypeIdentifiers

/// Sheets and confirmations that the browser can show.
enum BrowserSheet: Identifiable {
    case newFolder
    case rename(NodeItem)
    case move([UInt64])
    case copy([UInt64])
    case importItems([UInt64])
    case share(NodeItem)
    case link([NodeItem])
    case versions(NodeItem)

    var id: String {
        switch self {
        case .newFolder: "new"
        case let .rename(item): "rename\(item.id)"
        case let .move(ids): "move\(ids)"
        case let .copy(ids): "copy\(ids)"
        case let .importItems(ids): "import\(ids)"
        case let .share(item): "share\(item.id)"
        case let .link(items): "link\(items.map(\.id))"
        case let .versions(item): "versions\(item.id)"
        }
    }
}

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var sheet: BrowserSheet?
    @State private var confirmDelete: [UInt64]?
    @State private var confirmEmpty = false
    @State private var confirmRemoveLinks: [UInt64]?
    @State private var dropTargeted = false

    private var settings: AppSettings { app.settings }
    private var isAccount: Bool { model.engine.kind == .account }

    var body: some View {
        content
            .navigationTitle(model.title)
            .navigationSubtitle(subtitle)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: isAccount ? "Search MEGA" : "Search in Link")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .inspector(isPresented: Binding(get: { settings.showInspector }, set: { settings.showInspector = $0 })) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let web = urls.filter { !$0.isFileURL }
                if !web.isEmpty {
                    app.handleIncoming(web.map(\.absoluteString).joined(separator: "\n"), source: .drop)
                }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, canUpload, let folder = model.currentFolder else { return !web.isEmpty }
                app.upload(files, to: folder)
                return true
            } isTargeted: { dropTargeted = $0 && canUpload }
            .overlay {
                if dropTargeted {
                    DropOverlay(title: model.title)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: dropTargeted)
            .onChange(of: model.engine.nodeChange) { _, change in model.handle(change) }
            .onChange(of: model.newFolderRequested) { _, requested in
                guard requested else { return }
                model.newFolderRequested = false
                if canUpload { sheet = .newFolder }
            }
            .onKeyPress(.space) {
                guard let item = model.selectedItems.first, !item.isFolder else { return .ignored }
                preview(item)
                return .handled
            }
            .onDeleteCommand {
                let ids = Array(model.selection)
                guard !ids.isEmpty, isAccount, model.canModify else { return }
                if model.isRubbish { confirmDelete = ids } else { Task { await app.moveToRubbish(ids) } }
            }
            .focusedSceneValue(\.browser, model)
            .sheet(item: $sheet) { sheet in sheetView(sheet) }
            .confirmationDialog("Delete permanently?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    let ids = confirmDelete ?? []
                    Task { await app.deletePermanently(ids, engine: model.engine) }
                }
            } message: {
                Text("You cannot undo this.")
            }
            .confirmationDialog("Empty the Rubbish Bin?", isPresented: $confirmEmpty) {
                Button("Empty Rubbish Bin", role: .destructive) { Task { await app.emptyRubbishBin() } }
            } message: {
                Text("All items in the Rubbish Bin will be deleted permanently.")
            }
            .confirmationDialog(confirmRemoveLinks?.count == 1 ? "Remove the link?" : "Remove \(confirmRemoveLinks?.count ?? 0) links?",
                                isPresented: Binding(get: { confirmRemoveLinks != nil }, set: { if !$0 { confirmRemoveLinks = nil } }),
                                presenting: confirmRemoveLinks) { ids in
                Button(ids.count == 1 ? "Remove Link" : "Remove Links", role: .destructive) {
                    Task { await app.removeLinks(ids) }
                }
            } message: { ids in
                Text(ids.count == 1 ? "People who have the link can no longer open the item. A new link has a different address."
                                    : "People who have the links can no longer open the items. New links have different addresses.")
            }
    }

    private var canUpload: Bool { model.canUpload }

    private var subtitle: String {
        let count = model.items.count
        if !model.selection.isEmpty {
            let size = model.selectedItems.reduce(Int64(0)) { $0 + $1.size }
            return "\(model.selection.count) of \(count) selected · \(Format.bytes(size))"
        }
        return count == 1 ? "1 item" : "\(count) items"
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Could Not Load Items", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else if model.isLoading && model.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
        } else if settings.viewMode(of: model) == .list {
            NodeTable(model: model, menu: menu, open: open)
        } else {
            NodeGrid(model: model, size: settings.gridSize, menu: menu, open: open)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.isRubbish {
            ContentUnavailableView("Rubbish Bin Is Empty", systemImage: "trash")
        } else if canUpload {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("Drop files here to upload them.")
            } actions: {
                Button("Upload Files…") { upload(folders: false) }
                    .buttonStyle(.glass)
            }
        } else {
            ContentUnavailableView("No Items", systemImage: "tray")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: Binding(get: { settings.viewMode(of: model) }, set: { settings.setViewMode($0, of: model) })) {
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label("Grid", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("View as list or grid")

            Menu {
                Picker("Sort By", selection: Binding(get: { model.sortKey }, set: { model.setSort($0, ascending: model.ascending) })) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: Binding(get: { model.ascending }, set: { model.setSort(model.sortKey, ascending: $0) })) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
                if settings.viewMode(of: model) == .grid {
                    Divider()
                    Picker("Icon Size", selection: Binding(get: { settings.gridSize }, set: { settings.gridSize = $0 })) {
                        Text("Small").tag(104.0)
                        Text("Medium").tag(132.0)
                        Text("Large").tag(176.0)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            if canUpload {
                Button { sheet = .newFolder } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .help("New Folder")
                Menu {
                    Button("Upload Files…") { upload(folders: false) }
                    Button("Upload Folder…") { upload(folders: true) }
                } label: {
                    Label("Upload", systemImage: "arrow.up.doc")
                }
                .help("Upload")
            }
            if model.isRubbish {
                Button { confirmEmpty = true } label: { Label("Empty Rubbish Bin", systemImage: "trash.slash") }
                    .help("Empty Rubbish Bin")
            }
            if !isAccount {
                Button { downloadAll() } label: { Label("Download All", systemImage: "arrow.down.circle") }
                    .help("Download the whole folder")
                if app.session.isSignedIn {
                    Button { importAll() } label: { Label("Import All", systemImage: "square.and.arrow.down") }
                        .help("Import the whole folder to your Cloud Drive")
                }
            }
            Button { settings.showInspector.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Show or hide the inspector")
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                PathBar(model: model)
                Spacer(minLength: 0)
                TransferPill { app.transfersRequested = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: Actions

    private func open(_ ids: Set<UInt64>) {
        let items = model.items.filter { ids.contains($0.id) }
        if items.count == 1, let item = items.first, item.isFolder {
            model.go(to: .folder(item.id))
        } else if let item = items.first(where: { !$0.isFolder }) {
            preview(item)
        }
    }

    private func preview(_ item: NodeItem) {
        let media = model.items.filter { $0.kind == .image || $0.kind.isStreamable }.map(\.id)
        openWindow(value: PreviewRequest(engineID: model.engine.id, handle: item.id,
                                         siblings: media.contains(item.id) ? media : []))
    }

    private func upload(folders: Bool) {
        guard let folder = model.currentFolder else { return }
        app.chooseAndUpload(to: folder, folders: folders)
    }

    private func downloadAll() {
        let engine = model.engine
        let sdk = engine.sdk
        Task {
            guard let root = await EngineQueue.run({ sdk.rootNode?.handle }) else { return }
            app.download([root], from: engine)
        }
    }

    private func importAll() {
        let sdk = model.engine.sdk
        Task {
            guard let root = await EngineQueue.run({ sdk.rootNode?.handle }) else { return }
            sheet = .importItems([root])
        }
    }

    @ViewBuilder
    private func menu(_ ids: Set<UInt64>) -> some View {
        let items = model.items.filter { ids.contains($0.id) }
        let handles = items.map(\.id)
        if let first = items.first {
            let single = items.count == 1
            Button(single && first.isFolder ? "Open" : "Preview") { open(ids) }
            Button("Download") { app.download(handles, from: model.engine) }
            if !isAccount {
                if app.session.isSignedIn {
                    Button("Import to Cloud Drive…") { sheet = .importItems(handles) }
                }
            } else if model.isRubbish {
                Divider()
                Button("Restore") { Task { await app.restore(items) } }
                Button("Delete Permanently…", role: .destructive) { confirmDelete = handles }
            } else {
                let owned = model.canModify
                Divider()
                Button("Copy Link") { Task { await app.copyLinks(handles) } }
                Button("Manage Link…") { sheet = .link(items) }
                if items.contains(where: \.isExported) {
                    Button("Remove Link…") { confirmRemoveLinks = items.filter(\.isExported).map(\.id) }
                }
                if single, first.isFolder, model.location != .incomingShares {
                    Button("Share Folder…") { sheet = .share(first) }
                }
                Divider()
                if single, owned {
                    Button("Rename…") { sheet = .rename(first) }
                }
                if owned {
                    Button("Move To…") { sheet = .move(handles) }
                }
                Button("Copy To…") { sheet = .copy(handles) }
                Menu("Label") {
                    ForEach(NodeLabel.allCases, id: \.self) { label in
                        Button {
                            Task { await app.setLabel(handles, label) }
                        } label: {
                            if label == .none {
                                Text("No Label")
                            } else {
                                Label(label.title, systemImage: "circle.fill")
                                    .foregroundStyle(Color(nsColor: label.color))
                            }
                        }
                    }
                }
                let favourite = items.allSatisfy(\.isFavourite)
                Button(favourite ? "Remove from Favourites" : "Add to Favourites") {
                    Task { await app.setFavourite(handles, !favourite) }
                }
                if single, !first.isFolder {
                    Button("Versions…") { sheet = .versions(first) }
                }
                Button("Get Info") {
                    model.selection = ids
                    settings.showInspector = true
                }
                if owned {
                    Divider()
                    Button("Move to Rubbish Bin", role: .destructive) { Task { await app.moveToRubbish(handles) } }
                }
            }
        } else if canUpload {
            Button("New Folder…") { sheet = .newFolder }
            Button("Upload Files…") { upload(folders: false) }
            Button("Upload Folder…") { upload(folders: true) }
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: BrowserSheet) -> some View {
        switch sheet {
        case .newFolder:
            NameSheet(title: "New Folder", action: "Create", initial: "New Folder") { name in
                guard let folder = model.currentFolder else { return }
                Task { await app.createFolder(named: name, in: folder, engine: model.engine) }
            }
        case let .rename(item):
            NameSheet(title: "Rename", action: "Rename", initial: item.name) { name in
                Task { await app.rename(item.id, to: name, engine: model.engine) }
            }
        case let .move(ids):
            FolderPicker(title: "Move \(ids.count == 1 ? "Item" : "\(ids.count) Items")", action: "Move", exclude: Set(ids)) { folder in
                Task { await app.move(ids, to: folder) }
            }
        case let .copy(ids):
            FolderPicker(title: "Copy \(ids.count == 1 ? "Item" : "\(ids.count) Items")", action: "Copy", exclude: []) { folder in
                Task { await app.copy(ids, from: model.engine, to: folder) }
            }
        case let .importItems(ids):
            FolderPicker(title: "Import to Cloud Drive", action: "Import", exclude: []) { folder in
                Task { await app.copy(ids, from: model.engine, to: folder) }
            }
        case let .share(item):
            ShareSheet(item: item)
        case let .link(items):
            LinkSheet(items: items)
        case let .versions(item):
            VersionsSheet(item: item)
        }
    }
}

private struct DropOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.megaRed, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .padding(16)
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color.megaRed)
                Text("Upload to \(title)")
                    .font(.title3.weight(.semibold))
            }
            .padding(28)
            .glassPanel(cornerRadius: 24)
        }
        .allowsHitTesting(false)
    }
}

/// Clickable path of the current folder, on glass.
struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.crumbs.enumerated()), id: \.element.id) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                Button(crumb.title) { model.go(to: crumb.location) }
                    .buttonStyle(.plain)
                    .font(.callout.weight(index == model.crumbs.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == model.crumbs.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
            if model.isSearching {
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).imageScale(.small)
                Text("Search results").font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct BrowserFocusKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browser: BrowserModel? {
        get { self[BrowserFocusKey.self] }
        set { self[BrowserFocusKey.self] = newValue }
    }
}
