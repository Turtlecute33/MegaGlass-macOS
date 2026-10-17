import Foundation
import Observation

enum BrowserViewMode: String, CaseIterable {
    case list, grid
}

/// The view and sort that the user chose for one place.
struct FolderView: Equatable {
    /// Nil shows the default view.
    var mode: BrowserViewMode?
    var sortKey: SortKey
    var ascending: Bool

    init(mode: BrowserViewMode?, sortKey: SortKey, ascending: Bool) {
        self.mode = mode
        self.sortKey = sortKey
        self.ascending = ascending
    }

    /// From the saved form, "grid size desc" ("default" for no view).
    init?(saved: String) {
        let parts = saved.split(separator: " ").map(String.init)
        guard parts.count == 3, let key = SortKey(rawValue: parts[1]), ["asc", "desc"].contains(parts[2]) else { return nil }
        mode = BrowserViewMode(rawValue: parts[0])
        sortKey = key
        ascending = parts[2] == "asc"
    }

    var saved: String { "\(mode?.rawValue ?? "default") \(sortKey.rawValue) \(ascending ? "asc" : "desc")" }
}

/// User preferences, saved in UserDefaults.
@Observable
final class AppSettings {
    private enum Key {
        static let downloadFolder = "downloadFolder"
        static let askWhereToDownload = "askWhereToDownload"
        static let downloadConnections = "downloadConnections"
        static let uploadConnections = "uploadConnections"
        static let downloadLimit = "downloadLimitKB"
        static let uploadLimit = "uploadLimitKB"
        static let workerThreads = "workerThreads"
        static let showMenuBarExtra = "showMenuBarExtra"
        static let viewMode = "viewMode"
        static let showInspector = "showInspector"
        static let gridSize = "gridSize"
        static let clipboardWatch = "clipboardWatch"
        static let forwardBrowser = "forwardBrowser"
        static let previousBrowser = "previousBrowser"
        static let bypassAutoOpen = "bypassAutoOpen"
        static let bypassOrder = "bypassOrder"
        static let bypassDisabled = "bypassDisabled"
        static let bypassBlockAds = "bypassBlockAds"
        static let bypassKeepLargest = "bypassKeepLargest"
        static let protectorHosts = "protectorHosts"
        static let folderViews = "folderViews"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// The saved view of each place of the account, by place key (Location.viewKey). On this
    /// Mac only, and removed at logout.
    @ObservationIgnored private var folderViews: [String: String]

    var downloadFolder: URL {
        didSet { defaults.set(downloadFolder.path, forKey: Key.downloadFolder) }
    }
    var askWhereToDownload: Bool {
        didSet { defaults.set(askWhereToDownload, forKey: Key.askWhereToDownload) }
    }
    /// Parallel connections per transfer. The engine's desktop default is 8.
    var downloadConnections: Int {
        didSet { defaults.set(downloadConnections, forKey: Key.downloadConnections) }
    }
    var uploadConnections: Int {
        didSet { defaults.set(uploadConnections, forKey: Key.uploadConnections) }
    }
    /// KB/s, 0 means no limit.
    var downloadLimitKB: Int {
        didSet { defaults.set(downloadLimitKB, forKey: Key.downloadLimit) }
    }
    var uploadLimitKB: Int {
        didSet { defaults.set(uploadLimitKB, forKey: Key.uploadLimit) }
    }
    /// Threads for chunk encryption and MAC. Applies at next launch.
    var workerThreads: Int {
        didSet { defaults.set(workerThreads, forKey: Key.workerThreads) }
    }
    var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: Key.showMenuBarExtra) }
    }
    var viewMode: BrowserViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }
    var showInspector: Bool {
        didSet { defaults.set(showInspector, forKey: Key.showInspector) }
    }
    var gridSize: Double {
        didSet { defaults.set(gridSize, forKey: Key.gridSize) }
    }
    /// Opt-in: copied MEGA and protector links open in the app.
    var clipboardWatch: Bool {
        didSet { defaults.set(clipboardWatch, forKey: Key.clipboardWatch) }
    }
    /// Browser for non-MEGA links when MegaGlass is the default browser (app path).
    var forwardBrowser: String {
        didSet { defaults.set(forwardBrowser, forKey: Key.forwardBrowser) }
    }
    /// The default browser before MegaGlass took its place (app path).
    var previousBrowser: String {
        didSet { defaults.set(previousBrowser, forKey: Key.previousBrowser) }
    }
    var bypassAutoOpen: Bool {
        didSet { defaults.set(bypassAutoOpen, forKey: Key.bypassAutoOpen) }
    }
    var bypassOrder: [String] {
        didSet { defaults.set(bypassOrder, forKey: Key.bypassOrder) }
    }
    var bypassDisabled: [String] {
        didSet { defaults.set(bypassDisabled, forKey: Key.bypassDisabled) }
    }
    /// Blocks ad and pop-up networks in the Bypass web views.
    var bypassBlockAds: Bool {
        didSet { defaults.set(bypassBlockAds, forKey: Key.bypassBlockAds) }
    }
    /// A Bypass result with more MEGA links opens only this number of the largest; 0 opens all.
    var bypassKeepLargest: Int {
        didSet { defaults.set(bypassKeepLargest, forKey: Key.bypassKeepLargest) }
    }
    var protectorHosts: [String] {
        didSet { defaults.set(protectorHosts, forKey: Key.protectorHosts) }
    }

    init(defaults: UserDefaults? = nil) {
        #if MEGAGLASS_TESTS
        self.defaults = defaults ?? UserDefaults(suiteName: "app.megaglass.tests")!
        #else
        self.defaults = defaults ?? .standard
        #endif
        let defaults = self.defaults
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        downloadFolder = defaults.string(forKey: Key.downloadFolder).map { URL(filePath: $0) } ?? downloads
        askWhereToDownload = defaults.bool(forKey: Key.askWhereToDownload)
        downloadConnections = min(32, max(1, defaults.object(forKey: Key.downloadConnections) as? Int ?? 8))
        uploadConnections = min(32, max(1, defaults.object(forKey: Key.uploadConnections) as? Int ?? 8))
        downloadLimitKB = max(0, defaults.integer(forKey: Key.downloadLimit))
        uploadLimitKB = max(0, defaults.integer(forKey: Key.uploadLimit))
        let cores = ProcessInfo.processInfo.activeProcessorCount
        workerThreads = min(8, max(1, defaults.object(forKey: Key.workerThreads) as? Int ?? min(4, max(2, cores / 2))))
        showMenuBarExtra = defaults.object(forKey: Key.showMenuBarExtra) as? Bool ?? true
        viewMode = BrowserViewMode(rawValue: defaults.string(forKey: Key.viewMode) ?? "") ?? .list
        showInspector = defaults.bool(forKey: Key.showInspector)
        let savedGridSize = defaults.object(forKey: Key.gridSize) as? Double ?? 132
        gridSize = savedGridSize.isFinite ? min(220, max(96, savedGridSize)) : 132
        clipboardWatch = defaults.bool(forKey: Key.clipboardWatch)
        forwardBrowser = defaults.string(forKey: Key.forwardBrowser) ?? ""
        previousBrowser = defaults.string(forKey: Key.previousBrowser) ?? ""
        bypassAutoOpen = defaults.object(forKey: Key.bypassAutoOpen) as? Bool ?? true
        bypassDisabled = defaults.stringArray(forKey: Key.bypassDisabled) ?? []
        bypassBlockAds = defaults.object(forKey: Key.bypassBlockAds) as? Bool ?? true
        bypassKeepLargest = min(5, max(0, defaults.object(forKey: Key.bypassKeepLargest) as? Int ?? 2))
        var hosts = defaults.stringArray(forKey: Key.protectorHosts) ?? LinkSorter.defaultProtectorHosts
        // Version 2 added the Admaven domains, version 3 more mirror domains; add them once
        // to an older saved list.
        if defaults.integer(forKey: "protectorHostsVersion") < 3 {
            hosts += LinkSorter.defaultProtectorHosts.filter { !hosts.contains($0) }
            defaults.set(3, forKey: "protectorHostsVersion")
            defaults.set(hosts, forKey: Key.protectorHosts)
        }
        protectorHosts = hosts
        // New services go to their place in the default order.
        let order = defaults.stringArray(forKey: Key.bypassOrder) ?? []
        bypassOrder = order + BypassProvider.all.map(\.id).filter { !order.contains($0) }
        folderViews = defaults.dictionary(forKey: Key.folderViews) as? [String: String] ?? [:]
    }

    func folderView(for place: Location) -> FolderView? {
        folderViews[place.viewKey].flatMap(FolderView.init(saved:))
    }

    func setFolderView(_ view: FolderView, for place: Location) {
        folderViews[place.viewKey] = view.saved
        defaults.set(folderViews, forKey: Key.folderViews)
    }

    func clearFolderViews() {
        folderViews = [:]
        defaults.removeObject(forKey: Key.folderViews)
    }

    /// The view of [browser]: the view saved for its place, or the default view.
    func viewMode(of browser: BrowserModel?) -> BrowserViewMode {
        browser?.viewMode ?? viewMode
    }

    /// Keeps [mode] for the place that [browser] shows. A browser that keeps no views (a
    /// folder link) changes the default view.
    func setViewMode(_ mode: BrowserViewMode, of browser: BrowserModel?) {
        if let browser, browser.remembersViews { browser.setViewMode(mode) } else { viewMode = mode }
    }
}
