import Foundation
import Observation
@preconcurrency import MEGASdk
import MEGABridge

nonisolated enum Location: Hashable, Sendable {
    case folder(UInt64)
    case incomingShares
    case outgoingShares
    case publicLinks
    case favourites
    case recents
}

nonisolated enum SortKey: String, CaseIterable, Sendable {
    case name, size, modified, kind

    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Kind"
        }
    }

    func engineOrder(ascending: Bool) -> MEGASortOrderType {
        switch self {
        case .name, .kind: ascending ? .defaultAsc : .defaultDesc
        case .size: ascending ? .sizeAsc : .sizeDesc
        case .modified: ascending ? .modificationAsc : .modificationDesc
        }
    }
}

struct Crumb: Hashable, Identifiable {
    let location: Location
    let title: String
    var id: Location { location }
}

/// What a folder or list contains. Built on the engine read queue.
nonisolated struct Listing: Sendable {
    var items: [NodeItem] = []
    var crumbs: [(Location, String)] = []
    var canWrite = false
    var isRubbish = false
    var missing = false
    var errorMessage: String?
}

/// Navigation and contents for one browser (a window, or an open folder link).
@Observable
final class BrowserModel {
    let engine: MegaEngine
    let rootTitle: String

    private(set) var location: Location
    private(set) var items: [NodeItem] = []
    private(set) var crumbs: [Crumb] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var canWrite = false
    private(set) var isRubbish = false
    private(set) var isSearching = false
    var selection: Set<UInt64> = []
    /// Set by the New Folder menu command.
    var newFolderRequested = false
    var sortKey: SortKey = .name
    var ascending = true
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    @ObservationIgnored private var back: [Location] = []
    @ObservationIgnored private var forward: [Location] = []
    @ObservationIgnored private var itemIDs: Set<UInt64> = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchToken: MEGACancelToken?
    @ObservationIgnored private var loadSerial = 0
    /// The last engine change seen: a gap means that changes were merged before this one.
    @ObservationIgnored private var changeSerial: Int
    @ObservationIgnored private let listingProvider: (@Sendable (Location, SortKey, Bool) async -> Listing)?
    @ObservationIgnored private let searchProvider: (@Sendable (String) async -> [NodeItem])?

    init(engine: MegaEngine, start: Location, rootTitle: String = "Cloud Drive",
         sortKey: SortKey = .name, ascending: Bool = true,
         listingProvider: (@Sendable (Location, SortKey, Bool) async -> Listing)? = nil,
         searchProvider: (@Sendable (String) async -> [NodeItem])? = nil) {
        self.engine = engine
        self.location = start
        self.rootTitle = rootTitle
        self.sortKey = sortKey
        self.ascending = ascending
        self.listingProvider = listingProvider
        self.searchProvider = searchProvider
        changeSerial = engine.nodeChange.serial
        load()
    }

    func stop() {
        loadSerial += 1
        loadTask?.cancel()
        reloadTask?.cancel()
        searchTask?.cancel()
        searchToken?.cancel()
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { crumbs.count > 1 }
    var isFolderLink: Bool { engine.kind == .folderLink }
    /// Uploads and new folders: a writable account folder, not the Rubbish Bin or search results.
    var canUpload: Bool { engine.kind == .account && canWrite && !isRubbish && !isSearching }

    var title: String {
        if isSearching { return "Search" }
        return crumbs.last?.title ?? rootTitle
    }

    var selectedItems: [NodeItem] {
        items.filter { selection.contains($0.id) }
    }

    var currentFolder: UInt64? {
        if case let .folder(handle) = location { return handle }
        return nil
    }

    // MARK: Navigation

    func go(to target: Location) {
        guard target != location || isSearching else { return }
        back.append(location)
        forward.removeAll()
        navigate(target)
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(location)
        navigate(previous)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(location)
        navigate(next)
    }

    func goUp() {
        guard crumbs.count > 1 else { return }
        go(to: crumbs[crumbs.count - 2].location)
    }

    /// Resets history, for a sidebar section change.
    func reset(to target: Location) {
        back.removeAll()
        forward.removeAll()
        navigate(target)
    }

    private func navigate(_ target: Location) {
        location = target
        items = []
        itemIDs = []
        crumbs = []
        canWrite = false
        isRubbish = false
        selection.removeAll()
        if !searchText.isEmpty { searchText = "" }
        isSearching = false
        load()
    }

    // MARK: Loading

    func setSort(_ key: SortKey, ascending: Bool) {
        guard key != sortKey || ascending != self.ascending else { return }
        sortKey = key
        self.ascending = ascending
        if isSearching { scheduleSearch(immediately: true) } else { load() }
    }

    func reload() {
        if isSearching { scheduleSearch(immediately: true) } else { load() }
    }

    private func load() {
        loadTask?.cancel()
        searchTask?.cancel()
        searchToken?.cancel()
        loadSerial += 1
        let serial = loadSerial
        let target = location
        let sdk = engine.sdk
        let order = sortKey.engineOrder(ascending: ascending)
        let key = sortKey
        let ascending = ascending
        let rootTitle = rootTitle
        isLoading = items.isEmpty

        loadTask = Task {
            var listing: Listing
            if let listingProvider {
                listing = await listingProvider(target, key, ascending)
            } else {
                switch target {
                case .favourites:
                    listing = await Self.favourites(sdk: sdk)
                case .recents:
                    listing = await Self.recents(sdk: sdk)
                default:
                    listing = await EngineQueue.run {
                        Self.list(target, sdk: sdk, order: order, rootTitle: rootTitle)
                    }
                }
            }
            if key == .kind || !Self.engineSorted(target) {
                let unsorted = listing.items
                listing.items = await EngineQueue.run { Self.sort(unsorted, by: key, ascending: ascending) }
            }
            guard !Task.isCancelled, serial == loadSerial else { return }
            apply(listing)
        }
    }

    private func apply(_ listing: Listing) {
        errorMessage = listing.errorMessage
        items = listing.items
        itemIDs = Set(listing.items.map(\.id))
        crumbs = listing.crumbs.map { Crumb(location: $0.0, title: $0.1) }
        canWrite = listing.canWrite
        isRubbish = listing.isRubbish
        selection.formIntersection(itemIDs)
        isLoading = false
        #if MEGAGLASS_TESTS
        let fallBack = false
        #else
        let fallBack = true
        #endif
        if fallBack, listing.missing, case .folder = location, let first = crumbs.first, first.location != location {
            // The folder was deleted or moved away; go to the closest place that exists.
            navigate(first.location)
        }
    }

    /// Reloads only when the change touches what is on screen.
    func handle(_ change: NodeChange) {
        // The view sees only the last of changes that arrive close together: after a gap,
        // an earlier change can be for this folder.
        let missed = change.serial != changeSerial + 1
        changeSerial = change.serial
        let relevant: Bool
        switch location {
        case let .folder(handle):
            relevant = change.affects(folder: handle) || !change.handles.isDisjoint(with: itemIDs)
                || crumbs.contains { crumb in
                    if case let .folder(h) = crumb.location { return change.handles.contains(h) }
                    return false
                }
        default:
            relevant = true
        }
        guard relevant || missed || isSearching else { return }
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    // MARK: Search

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        searchToken?.cancel()
        loadTask?.cancel()
        loadSerial += 1
        let serial = loadSerial
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            isSearching = false
            load()
            return
        }
        isSearching = true
        let token = MEGACancelToken()
        searchToken = token
        let sdk = engine.sdk
        let folder = currentFolder
        let inFolderLink = isFolderLink
        let order = sortKey.engineOrder(ascending: ascending)
        let key = sortKey
        let ascending = ascending
        searchTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(220))
            }
            guard !Task.isCancelled else { return }
            let results: [NodeItem]
            if let searchProvider {
                results = await searchProvider(term)
            } else {
                results = await EngineQueue.run {
                    let filter: MEGASearchFilter
                    if let parent = folder ?? (inFolderLink ? sdk.rootNode?.handle : nil) {
                        filter = MEGASearchFilter(term: term, parentNodeHandle: parent, nodeType: .unknown,
                                                  category: .unknown, sensitiveFilter: .disabled,
                                                  favouriteFilter: .disabled, creationTimeFrame: nil,
                                                  modificationTimeFrame: nil)
                    } else {
                        // SEARCH_TARGET_ALL: Cloud Drive, Backups, Rubbish Bin and incoming shares.
                        filter = MEGASearchFilter(term: term, nodeType: .unknown, category: .unknown,
                                                  sensitiveFilter: .disabled, favouriteFilter: .disabled,
                                                  locationType: 4, creationTimeFrame: nil, modificationTimeFrame: nil)
                    }
                    let list = sdk.search(with: filter, orderType: order, page: nil, cancelToken: token)
                    let items = sdk.nodes(list).map { NodeItem($0) }
                    return key == .kind ? Self.sort(items, by: key, ascending: ascending) : items
                }
            }
            guard !Task.isCancelled, !token.isCancelled, serial == loadSerial else { return }
            errorMessage = nil
            items = results
            itemIDs = Set(results.map(\.id))
            selection.formIntersection(itemIDs)
            isLoading = false
        }
    }

    // MARK: Engine reads

    private nonisolated static func engineSorted(_ location: Location) -> Bool {
        switch location {
        case .folder, .publicLinks, .outgoingShares: true
        default: false
        }
    }

    nonisolated static func sort(_ items: [NodeItem], by key: SortKey, ascending: Bool) -> [NodeItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            var comparison: ComparisonResult
            switch key {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .size: comparison = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modified: comparison = a.modified.compare(b.modified)
            case .kind: comparison = a.kindTitle.compare(b.kindTitle)
            }
            if comparison == .orderedSame { comparison = a.name.localizedStandardCompare(b.name) }
            if comparison == .orderedSame { return a.id < b.id }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private nonisolated static func item(_ node: MEGANode, sdk: MEGASdk) -> NodeItem {
        NodeItem(node, folderSize: node.isFolder() ? sdk.size(for: node).int64Value : nil)
    }

    private nonisolated static func list(_ location: Location, sdk: MEGASdk, order: MEGASortOrderType, rootTitle: String) -> Listing {
        var listing = Listing()
        switch location {
        case let .folder(handle):
            guard let folder = sdk.node(forHandle: handle) else {
                listing.missing = true
                if let root = sdk.rootNode { listing.crumbs = [(.folder(root.handle), rootTitle)] }
                return listing
            }
            listing.items = sdk.nodes(sdk.children(forParent: folder, order: order.rawValue)).map { item($0, sdk: sdk) }
            listing.crumbs = crumbs(for: folder, sdk: sdk, rootTitle: rootTitle)
            let access = sdk.accessLevel(for: folder)
            listing.canWrite = access == .accessReadWrite || access == .accessFull || access == .accessOwner
            listing.isRubbish = folder.type == .rubbish || sdk.isNode(inRubbish: folder)
        case .incomingShares:
            listing.items = sdk.nodes(sdk.inShares()).map { item($0, sdk: sdk) }
            listing.crumbs = [(.incomingShares, "Incoming Shares")]
        case .outgoingShares:
            let shares = sdk.outShares(order)
            var seen = Set<UInt64>()
            listing.items = (0..<shares.size).compactMap { index in
                guard let share = shares.share(at: index), seen.insert(share.nodeHandle).inserted,
                      let node = sdk.node(forHandle: share.nodeHandle) else { return nil }
                return item(node, sdk: sdk)
            }
            listing.crumbs = [(.outgoingShares, "Outgoing Shares")]
        case .publicLinks:
            listing.items = sdk.nodes(sdk.publicLinks(order)).map { item($0, sdk: sdk) }
            listing.crumbs = [(.publicLinks, "Links")]
        case .favourites, .recents:
            break
        }
        return listing
    }

    private nonisolated static func crumbs(for folder: MEGANode, sdk: MEGASdk, rootTitle: String) -> [(Location, String)] {
        var result: [(Location, String)] = []
        let vault = sdk.vaultNode?.handle
        var current: MEGANode? = folder
        var visited = Set<UInt64>()
        while let node = current, visited.insert(node.handle).inserted {
            let title: String
            switch node.type {
            case .root: title = rootTitle
            case .rubbish: title = "Rubbish Bin"
            default: title = node.handle == vault ? "Backups" : LocalFileSafety.displayName(node.name ?? "Folder")
            }
            result.append((.folder(node.handle), title))
            if node.isInShare() {
                result.append((.incomingShares, "Incoming Shares"))
                break
            }
            current = sdk.parentNode(for: node)
        }
        return result.reversed()
    }

    private nonisolated static func favourites(sdk: MEGASdk) async -> Listing {
        var listing = Listing()
        listing.crumbs = [(.favourites, "Favourites")]
        let request: MEGARequest
        do { request = try await sdk.request { sdk.favourites(forParent: nil, count: 0, delegate: $0) } }
        catch { listing.errorMessage = error.localizedDescription; return listing }
        let handles = (request.megaHandleArray ?? []).map(\.uint64Value)
        listing.items = await EngineQueue.run {
            handles.compactMap { sdk.node(forHandle: $0) }.map { item($0, sdk: sdk) }
        }
        return listing
    }

    private nonisolated static func recents(sdk: MEGASdk) async -> Listing {
        var listing = Listing()
        listing.crumbs = [(.recents, "Recents")]
        let request: MEGARequest
        do {
            request = try await sdk.request {
                sdk.getRecentActionsAsync(sinceDays: 30, maxNodes: 500, excludeSensitives: false, delegate: $0)
            }
        } catch { listing.errorMessage = error.localizedDescription; return listing }
        let buckets = request.recentActionsBuckets ?? []
        var seen = Set<UInt64>()
        listing.items = buckets.flatMap { sdk.nodes($0.nodesList) }
            .filter { seen.insert($0.handle).inserted }
            .map { NodeItem($0) }
            .sorted { $0.modified > $1.modified }
        return listing
    }
}
