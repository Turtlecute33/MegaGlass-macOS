import AppKit
import Foundation
import Observation

/// Sorts text from any source (clipboard, bookmarklet, URL scheme, drag and drop) into
/// MEGA links, which open at once, and link-protector links, which go to Bypass.
nonisolated enum LinkSorter {
    struct Result: Sendable {
        var mega: [String] = []
        var protected: [String] = []
        var isEmpty: Bool { mega.isEmpty && protected.isEmpty }
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive])

    /// - Parameter protectorHosts: hosts that count as link protectors (the user can edit them).
    /// - Parameter allWebLinks: send every non-MEGA web link to Bypass (for explicit bypass requests).
    static func sort(_ text: String, protectorHosts: Set<String>, allWebLinks: Bool = false) -> Result {
        var result = Result()
        result.mega = LinkParser.links(in: text).map(\.0)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        for match in urlPattern.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            let link = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}>"))
            guard let host = URL(string: link)?.host()?.lowercased(), !isMega(host),
                  seen.insert(link).inserted else { continue }
            if allWebLinks || matches(host, protectorHosts) {
                result.protected.append(link)
            }
        }
        return result
    }

    static func isMega(_ host: String) -> Bool {
        ["mega.nz", "mega.co.nz", "mega.app", "mega.io"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func matches(_ host: String, _ hosts: Set<String>) -> Bool {
        hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static let defaultProtectorHosts: [String] = [
        "rapid-links.net", "speedy-links.com", "best-links.org", "fast-links.org", "ultra-links.net",
        "free-content.pro", "free-leaks.com", "mdlinkshub.com", "link-direct.pro", "linkvertise.com",
        "link-to.net", "link-center.net", "link-hub.net", "link-target.net", "direct-link.net",
        "file-link.net", "up-to-down.net", "loot-link.com", "lootdest.org", "lootdest.info",
        "lootlabs.gg", "links-loot.com", "loot-links.com", "work.ink", "workink.net", "ouo.io",
        "ouo.press", "shrinkme.io", "shrinkearn.com", "exe.io", "fc.lc", "adfoc.us", "sub2unlock.com",
        "sub2unlock.net", "rekonise.com", "mboost.me", "boost.ink", "bstlar.com", "lockr.so",
        "paster.so", "keeplinks.org", "linkshortify.com", "gplinks.co", "shrtco.de", "adshnk.com",
        "social-unlock.com",
    ]
}

/// Writes to the pasteboard and remembers the change, so the clipboard watch
/// does not act on the app's own copies.
enum Pasteboard {
    private(set) static var ownChangeCount = -1

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ownChangeCount = NSPasteboard.general.changeCount
    }
}

/// Opt-in: when you copy a MEGA or protector link anywhere, the app takes it.
/// The check is local; only the change counter is polled, and the text is read
/// only after a change. macOS asks once for "Paste from other apps".
@Observable
final class ClipboardWatcher {
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored var onText: ((String) -> Void)?

    var isRunning: Bool { timer != nil }

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        lastCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.3
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard count != Pasteboard.ownChangeCount,
              pasteboard.types?.contains(.string) == true,
              let text = pasteboard.string(forType: .string),
              text != lastText, text.contains("http") || text.contains("mega://") else { return }
        lastText = text
        onText?(text)
    }
}

/// Optional "default browser" mode, like magnet links for a torrent app: MEGA and
/// protector links from other apps come to MegaGlass; every other link goes on to
/// the real browser at once.
enum BrowserRouter {
    static var isDefaultBrowser: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Installed browsers other than MegaGlass.
    static func browsers() -> [URL] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .filter { isForwardTarget($0, ownBundleID: own) }
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The browser that gets non-MEGA links: the saved choice, else the current
    /// default browser, else the first browser found.
    static func target(saved: String) -> URL? {
        if !saved.isEmpty {
            let candidate = URL(filePath: saved)
            if isForwardTarget(candidate) { return candidate }
        }
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
           isForwardTarget(handler) {
            return handler
        }
        return browsers().first
    }

    static func isForwardTarget(_ app: URL, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let identifier = Bundle(url: app)?.bundleIdentifier else { return false }
        return identifier != (ownBundleID ?? AppPaths.bundleID) && identifier != AppPaths.bundleID
    }

    static func forward(_ urls: [URL], saved: String) {
        guard !urls.isEmpty, let browser = target(saved: saved) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: browser, configuration: configuration)
    }
}

/// A bookmark for any browser. One click sends the page address and all links on
/// the page to MegaGlass; the app keeps only MEGA and protector links.
enum Bookmarklet {
    static let source = """
    javascript:(()=>{const s=new Set([location.href]);document.querySelectorAll('a[href]').forEach(a=>{if(/^https?:/i.test(a.href))s.add(a.href)});const t=document.body?document.body.innerText:'';(t.match(/https?:\\/\\/[^\\s"'<>]+/g)||[]).forEach(u=>s.add(u));location.href='megaglass://open?links='+encodeURIComponent([...s].join('\\n'))})();
    """

    /// A local page with the bookmarklet as a link that you drag to the bookmarks bar.
    static func installPage() -> URL {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>MegaGlass bookmark</title>
        <style>body{font:16px -apple-system,sans-serif;max-width:620px;margin:60px auto;line-height:1.5;color:#222}
        a.b{display:inline-block;padding:12px 22px;border-radius:999px;background:#d90007;color:#fff;text-decoration:none;font-weight:600}
        @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}}</style></head><body>
        <h1>Send to MegaGlass</h1>
        <p>Drag this button to your bookmarks bar:</p>
        <p><a class="b" href="\(source.replacingOccurrences(of: "\"", with: "&quot;"))">Send to MegaGlass</a></p>
        <p>On any page, click the bookmark. MegaGlass opens the MEGA links on the page and resolves link-protector links in Bypass.
        The first time, the browser asks if it can open MegaGlass. Allow it.</p>
        </body></html>
        """
        let file = AppPaths.ensure(AppPaths.caches.appending(path: "bookmarklet")).appending(path: "MegaGlass bookmark.html")
        try? html.data(using: .utf8)?.write(to: file)
        return file
    }
}
