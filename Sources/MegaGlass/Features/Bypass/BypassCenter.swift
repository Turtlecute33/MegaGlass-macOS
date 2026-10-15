import AppKit
import Foundation
import Observation
import WebKit

/// A bypass service with an HTTP API: no web page, no captcha, no user action.
nonisolated struct BypassAPI: Hashable, Sendable {
    enum Method: Hashable, Sendable { case get, postJSON }

    let method: Method
    /// {url} is the encoded link (GET).
    let endpoint: String
    /// Header for the key, or nil for keyless APIs.
    let keyHeader: String?
    let bearer: Bool
    /// Extra headers that the service's own page sends.
    let headers: [String: String]
}

/// One bypass service.
nonisolated struct BypassProvider: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case api(BypassAPI)
        /// Web page in the private panel: the app fills the link in and presses the button.
        case page
        /// Last resort: the page of the link itself, with you.
        case direct
    }

    let id: String
    let name: String
    let kind: Kind
    /// Start address of page services. {url} is the encoded link.
    let start: String
    let input: String?
    let submit: String?
    let result: String?
    let note: String
    /// Link hosts that this service does not resolve (it is skipped for them).
    var unsupported: Set<String> = []
    /// Time limit of one API call.
    var timeout: Double = 60
    /// Runs only in the last step, in the panel with you (never in the background).
    var withYouOnly = false

    var host: String? { URL(string: start.replacingOccurrences(of: "{url}", with: "x"))?.host() }
    var needsKey: Bool {
        if case let .api(api) = kind { return api.keyHeader != nil }
        return false
    }
    var isAPI: Bool {
        if case .api = kind { return true }
        return false
    }

    private static func api(_ id: String, _ name: String, _ api: BypassAPI, _ note: String,
                            unsupported: Set<String> = [], timeout: Double = 60) -> BypassProvider {
        BypassProvider(id: id, name: name, kind: .api(api), start: api.endpoint, input: nil, submit: nil, result: nil,
                       note: note, unsupported: unsupported, timeout: timeout)
    }

    /// Admaven lockers; few services resolve them.
    static let admaven: Set<String> = ["rapid-links.net", "speedy-links.com", "best-links.org", "fast-links.org",
                                       "ultra-links.net", "free-content.pro", "free-leaks.com", "mdlinkshub.com"]

    func supports(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host()?.lowercased() else { return true }
        return !LinkSorter.matches(host, unsupported)
    }

    static let all: [BypassProvider] = [
        BypassProvider(id: "izen.lol-userscript", name: "izen.lol (userscript page)", kind: .page,
                       start: "https://izen.lol/userscript?url={url}&apikey={izenKey}&time=0",
                       input: nil, submit: nil, result: nil,
                       note: "First service of the last step, in the panel with you: the page of the official izen.lol userscript. Resolves Admaven. It uses your izen.lol key if you add one.",
                       withYouOnly: true),
        api("rip.linkvertise.lol", "rip.linkvertise.lol",
            BypassAPI(method: .get, endpoint: "https://trw.lat/api/bypass?url={url}&mode=stream", keyHeader: nil, bearer: false,
                      headers: ["Origin": "https://rip.linkvertise.lol", "Referer": "https://rip.linkvertise.lol/"]),
            "Free API, no key.", timeout: 40),
        api("bypasskit", "BypassKit",
            BypassAPI(method: .postJSON, endpoint: "https://bypasskit.co/api/bypass", keyHeader: nil, bearer: false,
                      headers: ["Origin": "https://bypasskit.co", "Referer": "https://bypasskit.co/"]),
            "Free API, no key. Does not resolve Admaven.", unsupported: admaven),
        api("izen-api", "izen.lol API",
            BypassAPI(method: .get, endpoint: "https://api.izen.lol/v1/bypass?url={url}", keyHeader: "x-api-key", bearer: false, headers: [:]),
            "API key from izen.lol. Lists Admaven (rapid-links, speedy-links) as supported."),
        api("bypass.vip-api", "bypass.vip API",
            BypassAPI(method: .get, endpoint: "https://api.bypass.vip/premium/bypass?url={url}", keyHeader: "x-api-key", bearer: false, headers: [:]),
            "Premium API key from bypass.vip."),
        api("link-bypass", "link-bypass.com API",
            BypassAPI(method: .postJSON, endpoint: "https://link-bypass.com/api/v1/bypass", keyHeader: "X-API-Key", bearer: false, headers: [:]),
            "API key from link-bypass.com."),
        api("bypasslink.dev", "bypasslink.dev API",
            BypassAPI(method: .postJSON, endpoint: "https://api.bypasslink.dev/v1/bypass", keyHeader: "Authorization", bearer: true, headers: [:]),
            "API token from bypasslink.dev."),
        BypassProvider(id: "bypass.city", name: "bypass.city", kind: .page,
                       start: "https://bypass.city/bypass?bypass={url}", input: nil, submit: nil, result: nil,
                       note: "Web page (captcha). Resolves Admaven lockers."),
        BypassProvider(id: "bypass.tools", name: "bypass.tools", kind: .page,
                       start: "https://bypass.tools/", input: "input[type=url]", submit: nil, result: nil,
                       note: "Web page, in the background (Turnstile check)."),
        BypassProvider(id: "bypass.vip", name: "bypass.vip", kind: .page,
                       start: "https://bypass.vip/", input: "#bypassInput", submit: "#submitButton", result: nil,
                       note: "Web page (hCaptcha): only with you, at the end."),
        BypassProvider(id: "bypass.link", name: "bypass.link", kind: .page,
                       start: "https://bypass.link/",
                       input: "input[name=url], input[name=link], input[type=url], #generator input[type=text]:not([readonly])",
                       submit: "#gocaptcha, #generate-button", result: "#bypass_link",
                       note: "Web page (hCaptcha): only with you, at the end."),
        BypassProvider(id: "direct", name: "The page itself", kind: .direct,
                       start: "", input: nil, submit: nil, result: nil,
                       note: "Last resort: you do the steps of the page in the panel; MEGA links are collected."),
    ]
}

@Observable
final class BypassJob: Identifiable {
    enum Status: Equatable {
        case waiting
        case running(String)
        case needsYou(String)
        case done(Int)
        case failed(String)
    }

    let id = UUID()
    let link: String
    var status: Status = .waiting
    var megaLinks: [String] = []
    /// What each service did, for the list.
    var attempts: [String] = []
    var opened = false
    /// Links already tried, and the number of pages and lockers tried (a limit for loops).
    @ObservationIgnored var visited = Set<String>()
    @ObservationIgnored var steps = 0
    /// The link after the HTTP redirects (a mirror domain goes to the locker itself).
    @ObservationIgnored var target: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(link: String) { self.link = link }

    /// Marks a link as tried. False when it was tried before or the job has done enough steps.
    func visit(_ url: URL) -> Bool {
        steps += 1
        return steps <= 16 && visited.insert(url.absoluteString).inserted
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed: true
        default: false
        }
    }
}

/// Queue and engine of the all-in-one bypass. Up to `parallelJobs` links run at the same time.
/// Step 1, automatic: the app reads the link (redirects, pastes), then the APIs, then
/// web services in the background, then the result pages.
/// Step 2, only when step 1 fails: the services that wanted a captcha, then the page
/// itself, in the panel with you.
/// The panel (the web view) is one: the jobs take turns there.
@Observable
final class BypassCenter {
    private(set) var jobs: [BypassJob] = []
    private(set) var current: BypassJob?
    private(set) var provider: BypassProvider?
    private(set) var browser: BypassBrowser?
    /// True while the panel waits for you.
    private(set) var waitingForYou = false

    @ObservationIgnored var onError: ((any Error) -> Void)?
    @ObservationIgnored var onLinks: (([String]) -> Void)?
    @ObservationIgnored var onNeedsYou: ((String) -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var panelBusy = false
    @ObservationIgnored private var panelQueue: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var skipRequested = false
    @ObservationIgnored private var collectRequested = false
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": BypassBrowser.userAgent]
        return URLSession(configuration: configuration)
    }()

    private static let keychainService = "app.megaglass.bypass"

    /// Hosts that are never a bypass result (ads, captchas, social links of the services).
    private static let ignoredHosts: Set<String> = [
        "google.com", "googlesyndication.com", "doubleclick.net", "googleadservices.com", "gstatic.com",
        "googleapis.com", "googletagmanager.com", "google-analytics.com", "cloudflare.com", "hcaptcha.com",
        "recaptcha.net", "discord.gg", "discord.com", "t.me", "telegram.me", "twitter.com", "x.com",
        "youtube.com", "youtu.be", "github.com", "facebook.com", "instagram.com", "tiktok.com", "reddit.com",
        "patreon.com", "ko-fi.com", "paypal.com", "buymeacoffee.com", "apple.com", "trustpilot.com",
        "addons.mozilla.org", "chromewebstore.google.com", "greasyfork.org", "linktr.ee", "jsdelivr.net",
        "cloudfront.net", "profitableratecpmnetwork.com",
    ]

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Services and keys

    var providers: [BypassProvider] {
        let order = settings.bypassOrder
        return BypassProvider.all.sorted { a, b in
            (order.firstIndex(of: a.id) ?? Int.max) < (order.firstIndex(of: b.id) ?? Int.max)
        }
    }

    func isEnabled(_ provider: BypassProvider) -> Bool {
        if provider.needsKey && (key(for: provider) ?? "").isEmpty { return false }
        return !settings.bypassDisabled.contains(provider.id)
    }

    func setEnabled(_ provider: BypassProvider, _ enabled: Bool) {
        var disabled = Set(settings.bypassDisabled)
        if enabled { disabled.remove(provider.id) } else { disabled.insert(provider.id) }
        settings.bypassDisabled = Array(disabled)
    }

    func move(_ provider: BypassProvider, by offset: Int) {
        var order = providers.map(\.id)
        guard let index = order.firstIndex(of: provider.id) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        settings.bypassOrder = order
    }

    func key(for provider: BypassProvider) -> String? {
        Keychain.read(account: provider.id, service: Self.keychainService)
    }

    @discardableResult
    func setKey(_ key: String?, for provider: BypassProvider) -> Bool {
        do {
            if let key, !key.isEmpty {
                try Keychain.save(key, account: provider.id, service: Self.keychainService)
            } else {
                try Keychain.delete(account: provider.id, service: Self.keychainService)
            }
            return true
        } catch {
            onError?(error)
            return false
        }
    }

    // MARK: Queue

    func enqueue(_ links: [String]) {
        var known = Set(jobs.filter { !$0.isFinished }.map(\.link))
        for link in links where known.insert(link).inserted {
            jobs.append(BypassJob(link: link))
        }
        startIfNeeded()
    }

    /// A new job takes the place of the old one, which stops.
    func retry(_ job: BypassJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        stop(job)
        jobs[index] = BypassJob(link: job.link)
        startIfNeeded()
    }

    func remove(_ job: BypassJob) {
        stop(job)
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
    }

    func shutdown() {
        jobs.forEach { stop($0) }
        browser?.stop()
        session.invalidateAndCancel()
    }

    func skipService() { skipRequested = true }

    /// Takes the MEGA links that the panel shows now.
    func collectNow() { collectRequested = true }

    /// Stops the job in the panel.
    func cancelCurrent() {
        if let current { stop(current) }
    }

    /// The job stops at its next check, then gives the panel to the next job.
    private func stop(_ job: BypassJob) {
        if !job.isFinished { job.status = .failed("Stopped") }
        job.task?.cancel()
        if job === current { browser?.stop() }
    }

    func openLinks(of job: BypassJob) {
        guard !job.megaLinks.isEmpty else { return }
        job.opened = true
        onLinks?(job.megaLinks)
    }

    /// Links that run at the same time. A low number keeps the load on the free services low.
    private static let parallelJobs = 4

    private func startIfNeeded() {
        for job in jobs where job.status == .waiting && job.task == nil {
            guard jobs.count(where: { $0.task != nil }) < Self.parallelJobs else { return }
            if browser == nil { browser = BypassBrowser() }
            job.status = .running("Reading the link")
            job.task = Task {
                await run(job)
                job.task = nil
                startIfNeeded()
            }
        }
    }

    private func run(_ job: BypassJob) async {
        var assist: [BypassProvider] = []
        var links = await automatic(job.link, job: job, depth: 0, assist: &assist)
        if links.isEmpty, !Task.isCancelled {
            job.steps = 0
            links = await withYou(job, assist: assist)
        }
        guard !Task.isCancelled else {
            // A step can set a status after the stop.
            job.status = .failed("Stopped")
            return
        }
        job.megaLinks = links
        job.status = links.isEmpty ? .failed(Self.failureText(for: job.link)) : .done(links.count)
        if !links.isEmpty, settings.bypassAutoOpen { openLinks(of: job) }
    }

    // MARK: Panel

    /// Runs work in the panel. The jobs take turns; a job that has the panel keeps it.
    /// Nil when the job stops before its turn.
    private func withPanel<T>(_ job: BypassJob, waiting: String, _ work: () async -> T) async -> T? {
        if current === job { return await work() }
        if panelBusy {
            guard !Task.isCancelled else { return nil }
            job.status = .running(waiting)
            let id = UUID()
            let given = await withTaskCancellationHandler {
                await withCheckedContinuation { panelQueue.append((id, $0)) }
            } onCancel: {
                Task { @MainActor in self.leavePanelQueue(id) }
            }
            guard given else { return nil }
        } else {
            panelBusy = true
        }
        current = job
        skipRequested = false
        collectRequested = false
        defer { givePanelOn() }
        guard !Task.isCancelled else { return nil }
        return await work()
    }

    private func givePanelOn() {
        current = nil
        provider = nil
        waitingForYou = false
        browser?.stop()
        if panelQueue.isEmpty {
            panelBusy = false
        } else {
            panelQueue.removeFirst().turn.resume(returning: true)
        }
    }

    private func leavePanelQueue(_ id: UUID) {
        guard let index = panelQueue.firstIndex(where: { $0.id == id }) else { return }
        panelQueue.remove(at: index).turn.resume(returning: false)
    }

    private static func isAdmaven(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host()?.lowercased() else { return false }
        return LinkSorter.matches(host, BypassProvider.admaven)
    }

    private static func failureText(for link: String) -> String {
        guard isAdmaven(link) else { return "No MEGA links found" }
        return "Admaven locker: its address is given only after an offer, so free services cannot open it. Add an izen.lol or bypass.vip API key in Settings > Bypass."
    }

    // MARK: Step 1: automatic

    private nonisolated enum Outcome: Sendable {
        case mega([String])
        case result(URL)
        case failed(String)
        /// A captcha needs you; the service is kept for step 2.
        case needsYou
    }

    private nonisolated enum APIEvent: Sendable {
        case answer(Int, Outcome)
        case headStartOver(Int)
    }

    /// Links in a chain (a locker, a paste, a locker in that paste…).
    private static let maxDepth = 5
    /// Time that each API service has alone before the next one starts too.
    private static let headStart: Duration = .seconds(5)

    private func automatic(_ link: String, job: BypassJob, depth: Int, assist: inout [BypassProvider]) async -> [String] {
        guard let original = URL(string: link), job.visit(original) else { return [] }
        var link = link
        // The app first reads the link itself: short links, mirror domains and pastes need no service.
        let local = await readLocally(original, job: job, depth: depth, assist: &assist)
        // A locker found after the link, that is not there any more, needs no service.
        guard local.links.isEmpty, !(local.gone && depth > 0) else { return local.links }
        if let resolved = local.resolved, isProtector(resolved) || !isProtector(original) {
            job.attempts.append("Redirect: \(resolved.host() ?? resolved.absoluteString)")
            job.visited.insert(resolved.absoluteString)
            link = resolved.absoluteString
        }
        if depth == 0 { job.target = link }
        let apis = providers.filter { isEnabled($0) && $0.isAPI && !$0.withYouOnly && $0.supports(link) }
        let links = await viaAPIs(apis, link: link, job: job, depth: depth, assist: &assist)
        // The web services are slow: they get the link itself, not the lockers found after it.
        guard links.isEmpty, depth == 0 else { return links }
        let pages = providers.filter { isEnabled($0) && $0.kind == .page && $0.supports(link) && !$0.withYouOnly }
        // An Admaven locker gives its address only after a captcha or an offer. In the
        // background the web services stop at the captcha or go to an ad page: they wait
        // for you at once.
        if Self.isAdmaven(link) {
            for page in pages where !assist.contains(page) { assist.append(page) }
            job.attempts.append("Admaven locker: the services with a captcha wait for you")
            return []
        }
        return await withPanel(job, waiting: "Waits for the panel") {
            for provider in pages {
                guard !Task.isCancelled else { return [] }
                self.provider = provider
                skipRequested = false
                collectRequested = false
                job.status = .running(provider.name)
                let outcome = await viaPage(provider, link: link, job: job, interactive: false)
                let links = await use(outcome, from: provider, link: link, job: job, depth: depth, assist: &assist)
                if !links.isEmpty { return links }
            }
            return []
        } ?? []
    }

    /// The API services run together, in order. The next one starts when those before it
    /// have failed, or when they give no answer in `headStart`. Thus a slow service does
    /// not stop the queue, and a fast answer sends the link to one service only.
    private func viaAPIs(_ apis: [BypassProvider], link: String, job: BypassJob, depth: Int,
                         assist: inout [BypassProvider]) async -> [String] {
        let delay = Self.headStart
        return await withTaskGroup(of: APIEvent.self) { group in
            var started = 0
            var running: [Int] = []
            @MainActor func startNext() {
                guard started < apis.count, case let .api(api) = apis[started].kind else { return }
                let index = started, provider = apis[index]
                started += 1
                running.append(index)
                group.addTask { .answer(index, await self.viaAPI(api, provider: provider, link: link)) }
                if started < apis.count {
                    group.addTask {
                        try? await Task.sleep(for: delay)
                        return .headStartOver(index)
                    }
                }
                job.status = .running(running.map { apis[$0].name }.joined(separator: " + "))
            }
            startNext()
            while !running.isEmpty, !Task.isCancelled, let event = await group.next() {
                switch event {
                case let .headStartOver(index):
                    if index == started - 1 { startNext() }
                case let .answer(index, outcome):
                    running.removeAll { $0 == index }
                    let links = await use(outcome, from: apis[index], link: link, job: job, depth: depth, assist: &assist)
                    if !links.isEmpty {
                        group.cancelAll()
                        return links
                    }
                    if running.isEmpty { startNext() }
                }
            }
            group.cancelAll()
            return []
        }
    }

    /// Writes what a service did and follows its result.
    private func use(_ outcome: Outcome, from provider: BypassProvider, link: String, job: BypassJob,
                     depth: Int, assist: inout [BypassProvider]) async -> [String] {
        switch outcome {
        case let .mega(links):
            job.attempts.append("\(provider.name): \(links.count) MEGA link(s)")
            return links
        case let .result(url):
            if Self.isSameLocker(url, link) {
                job.attempts.append("\(provider.name): only the next redirect of the same locker")
                return []
            }
            job.attempts.append("\(provider.name): \(url.host() ?? url.absoluteString)")
            // A web service can go to an ad page by itself: its result gets no slow script
            // check, and the service is kept for the end, where you can solve its captcha.
            let links = await follow(url, job: job, depth: depth + 1, scripts: provider.isAPI, assist: &assist)
            if links.isEmpty, !provider.isAPI, !assist.contains(provider) { assist.append(provider) }
            return links
        case let .failed(reason):
            job.attempts.append("\(provider.name): \(reason)")
        case .needsYou:
            job.attempts.append("\(provider.name): captcha, kept for the end")
            if !assist.contains(provider) { assist.append(provider) }
        }
        return []
    }

    /// A "result" on a mirror domain with the same locker ID is only a redirect.
    private static func isSameLocker(_ url: URL, _ link: String) -> Bool {
        guard let original = URL(string: link) else { return false }
        if url.absoluteString == link { return true }
        let key = { (u: URL) in u.path(percentEncoded: false) + "?" + (u.query(percentEncoded: false) ?? "") }
        let host = url.host()?.lowercased() ?? ""
        let originalHost = original.host()?.lowercased() ?? ""
        let sameFamily = LinkSorter.matches(host, BypassProvider.admaven) && LinkSorter.matches(originalHost, BypassProvider.admaven)
        return (sameFamily || host == originalHost) && key(url) == key(original)
    }

    /// Reads a result: MEGA links in the address, another protector, or a page with links.
    private func follow(_ url: URL, job: BypassJob, depth: Int, scripts: Bool = true,
                        assist: inout [BypassProvider]) async -> [String] {
        let direct = LinkParser.links(in: url.absoluteString).map(\.0)
        if !direct.isEmpty { return direct }
        guard depth <= Self.maxDepth, !Task.isCancelled else { return [] }
        if isProtector(url) {
            job.attempts.append("Next protector: \(url.host() ?? url.absoluteString)")
            return await automatic(url.absoluteString, job: job, depth: depth, assist: &assist)
        }
        guard job.visit(url) else { return [] }
        // Most result pages (pastes, link lists) have the links in their HTML.
        let local = await readLocally(url, job: job, depth: depth, assist: &assist)
        if !local.links.isEmpty { return local.links }
        if let resolved = local.resolved, isProtector(resolved) {
            return await follow(resolved, job: job, depth: depth + 1, assist: &assist)
        }
        // Pages that build their links with scripts.
        var links: [String] = []
        if scripts, !local.gone {
            links = await withPanel(job, waiting: "Waits for the panel") {
                job.status = .running("Reading the result")
                return await collect(at: local.resolved ?? url, job: job, waitFor: 25, interactive: false)
            } ?? []
        }
        if links.isEmpty { job.attempts.append("No MEGA links in the result page") }
        return links
    }

    private func isProtector(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return LinkSorter.matches(host, Set(settings.protectorHosts))
    }

    /// What the app finds in a link with no service.
    private struct LocalRead {
        var links: [String] = []
        /// The address after the HTTP redirects, when it is a different one.
        var resolved: URL?
        /// The page is not there (HTTP 404 or 410).
        var gone = false
    }

    /// Reads a link on this Mac: the HTTP redirects (short links, mirror domains), the MEGA
    /// links in the HTML, and the links that go on (a chain of pastes, a locker in a paste).
    private func readLocally(_ url: URL, job: BypassJob, depth: Int, assist: inout [BypassProvider]) async -> LocalRead {
        if let destination = Self.embeddedDestination(in: url) {
            job.attempts.append("Destination in the address: \(destination.host() ?? destination.absoluteString)")
            return LocalRead(links: await follow(destination, job: job, depth: depth + 1, assist: &assist))
        }
        job.status = .running("Reading the page")
        var page = await fetchPage(url)
        // Some paste sites send part of the visits to another site, where the page is not there.
        for _ in 0..<4 {
            guard let (final, status, _) = page, status == 404 || status == 410,
                  final.host() != url.host(), !Task.isCancelled else { break }
            page = await fetchPage(url)
        }
        guard let (final, status, html) = page else { return LocalRead() }
        var read = LocalRead(links: LinkParser.links(in: html).map(\.0),
                             resolved: final.absoluteString == url.absoluteString ? nil : final,
                             gone: status == 404 || status == 410)
        if read.gone { job.attempts.append("\(final.host() ?? "The page"): HTTP \(status), the page is not there") }
        if !read.links.isEmpty {
            job.attempts.append("\(final.host() ?? "The page"): \(read.links.count) MEGA link(s) in the page")
            return read
        }
        // A locker page has links to its own sites only; look for other lockers in other pages.
        let protectors = isProtector(final) ? [] : Set(settings.protectorHosts)
        for next in Self.nextLinks(in: html, page: final, protectors: protectors).prefix(2) {
            guard !Task.isCancelled else { break }
            job.attempts.append("Next link: \(next.host() ?? next.absoluteString)")
            read.links = await follow(next, job: job, depth: depth + 1, assist: &assist)
            if !read.links.isEmpty { break }
        }
        return read
    }

    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.{0,400}?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>\\]+"#, options: [.caseInsensitive])

    /// The links of a page that go on to the MEGA links: "Mega link" buttons (a chain of
    /// pastes), and links to the lockers in `protectors` (a locker in a paste).
    static func nextLinks(in html: String, page: URL, protectors: Set<String>) -> [URL] {
        var found: [URL] = []
        func add(_ url: URL) {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url != page, !found.contains(url) { found.append(url) }
        }
        let range = NSRange(html.startIndex..., in: html)
        for match in anchorPattern.matches(in: html, range: range) {
            guard let href = Range(match.range(at: 1), in: html), let text = Range(match.range(at: 2), in: html),
                  html[text].range(of: "mega", options: .caseInsensitive) != nil,
                  let url = URL(string: html[href].replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL,
                  let host = url.host()?.lowercased(), !LinkSorter.isMega(host), !isIgnored(host) else { continue }
            add(url)
        }
        let pageHost = page.host()?.lowercased()
        for match in urlPattern.matches(in: html, range: range) where !protectors.isEmpty {
            guard let span = Range(match.range, in: html),
                  let url = URL(string: html[span].replacingOccurrences(of: "&amp;", with: "&")),
                  let host = url.host()?.lowercased(), host != pageHost, url.path().count > 1 else { continue }
            // Locker links are on the domain itself; subdomains are its scripts and pages.
            if protectors.contains(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) { add(url) }
        }
        return found
    }

    /// Linkvertise "dynamic" links have the destination in the address, in Base64 (r=…).
    static func embeddedDestination(in url: URL) -> URL? {
        guard url.path().contains("/dynamic"),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "r" })?.value else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8),
              let destination = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(destination.scheme?.lowercased() ?? "") else { return nil }
        return destination
    }

    private func viaAPI(_ api: BypassAPI, provider: BypassProvider, link: String) async -> Outcome {
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? link
        guard let url = URL(string: api.endpoint.replacingOccurrences(of: "{url}", with: encoded)) else {
            return .failed("Bad address")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        for (name, value) in api.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let header = api.keyHeader, let key = key(for: provider) {
            request.setValue(api.bearer ? "Bearer \(key)" : key, forHTTPHeaderField: header)
        }
        if api.method == .postJSON {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": link])
        }
        do {
            let finished = request
            let reply = try await withTimeout(seconds: provider.timeout) { [session] in
                try await Self.readReply(session: session, request: finished)
            }
            return Self.outcome(from: reply)
        } catch is TimeoutError {
            return .failed("No answer in time")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Reads a JSON reply or an event stream ("data: {...}" lines).
    private nonisolated static func readReply(session: URLSession, request: URLRequest) async throws -> APIReply {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("event-stream") {
            var last = APIReply(status: status)
            var received = 0
            for try await line in bytes.lines {
                received += line.utf8.count
                guard received <= 4_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                last = APIReply(status: status, object: object)
                if last.isFinal { return last }
            }
            return last
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 4_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return APIReply(status: status, object: object ?? [:], text: String(data: data, encoding: .utf8))
    }

    /// The parts of the many reply formats that matter.
    nonisolated struct APIReply: Sendable {
        var status: Int
        var success: Bool?
        var result: String?
        var message: String?

        init(status: Int, object: [String: Any] = [:], text: String? = nil) {
            self.status = status
            let nested = object["data"] as? [String: Any] ?? [:]
            func string(_ keys: [String]) -> String? {
                for key in keys {
                    if let value = object[key] as? String, !value.isEmpty { return value }
                    if let value = nested[key] as? String, !value.isEmpty { return value }
                }
                return nil
            }
            if let flag = object["success"] as? Bool {
                success = flag
            } else if let state = object["status"] as? String {
                success = state == "success" ? true : (state == "error" || state == "failed" ? false : nil)
            }
            result = string(["finalUrl", "destination", "bypassed", "result", "url", "link", "bypassed_url"])
            message = string(["error", "message", "detail", "reason"]) ?? (success == false ? result : nil)
            if result == nil, object.isEmpty, let text, text.count < 4000 { result = text }
        }

        var isFinal: Bool { success != nil }
    }

    private static func outcome(from reply: APIReply) -> Outcome {
        if reply.success == false || !(200..<300).contains(reply.status) {
            return .failed(reply.message ?? "HTTP \(reply.status)")
        }
        guard let result = reply.result else { return .failed(reply.message ?? "No result") }
        let mega = LinkParser.links(in: result).map(\.0)
        if !mega.isEmpty { return .mega(mega) }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .result(url) }
        if let first = trimmed.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression),
           let url = URL(string: String(trimmed[first])) {
            return .result(url)
        }
        return .failed("The result has no link")
    }

    /// Loads a page and its HTTP redirects; returns the last address, the HTTP status and
    /// the text (empty for an error page). Files are not loaded; only the first 4 MB of a page are read.
    private func fetchPage(_ url: URL) async -> (URL, Int, String)? {
        await Self.readPage(url, session: session)
    }

    /// Off the main thread: a page can be large.
    @concurrent private nonisolated static func readPage(_ url: URL, session: URLSession) async -> (URL, Int, String)? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        if http.statusCode >= 400 {
            bytes.task.cancel()
            return (http.url ?? url, http.statusCode, "")
        }
        guard type.hasPrefix("text/") || type.contains("html") || type.contains("json") else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4_000_000 { break }
            }
        } catch {
            return nil
        }
        bytes.task.cancel()
        // Links in scripts and JSON have escaped slashes.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #"\/"#, with: "/")
        return (http.url ?? url, http.statusCode, text)
    }

    private func viaPage(_ provider: BypassProvider, link: String, job: BypassJob, interactive: Bool) async -> Outcome {
        guard let browser else { return .failed("No browser") }
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? link
        let izenKey = BypassProvider.all.first { $0.id == "izen-api" }.flatMap { key(for: $0) } ?? ""
        guard let start = URL(string: provider.start.replacingOccurrences(of: "{url}", with: encoded)
            .replacingOccurrences(of: "{izenKey}", with: izenKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) else {
            return .failed("Bad address")
        }
        browser.load(start)
        await browser.waitUntilLoaded(timeout: 25)
        let baseline = Set((await browser.scan(resultSelector: provider.result))?.allLinks ?? [])
        let origin = URL(string: link)?.host()?.lowercased()
        let serviceHost = provider.host?.lowercased()
        func isService(_ host: String) -> Bool {
            guard let serviceHost else { return false }
            return host == serviceHost || host.hasSuffix("." + serviceHost)
        }

        var deadline = Date().addingTimeInterval(interactive ? 180 : 45)
        var captchaSince: Date?
        var clicks = 0
        var lastClick = Date.distantPast
        var lastCandidate: String?
        while Date() < deadline {
            guard !Task.isCancelled else { return .failed("Stopped") }
            if skipRequested { return .failed("Skipped") }
            try? await Task.sleep(for: .milliseconds(700))

            if let input = provider.input, clicks < 3, Date().timeIntervalSince(lastClick) > 12 {
                let state = await browser.fill(link: link, input: input, submit: provider.submit)
                if state == "clicked" || state == "submitted" || state == "enter" {
                    clicks += 1
                    lastClick = Date()
                }
            }
            guard let page = await browser.scan(resultSelector: provider.result) else { continue }
            if !page.mega.isEmpty || collectRequested {
                try? await Task.sleep(for: .milliseconds(900))
                let final = await browser.scan(resultSelector: provider.result)
                return .mega(final?.mega ?? page.mega)
            }
            if page.captcha {
                captchaSince = captchaSince ?? Date()
                // In step 1 nobody waits for a captcha: Turnstile often passes by itself in
                // a few seconds; if not, the service waits for step 2.
                if !interactive, Date().timeIntervalSince(captchaSince!) > 12 { return .needsYou }
                if interactive { deadline = max(deadline, Date().addingTimeInterval(30)) }
            } else {
                captchaSince = nil
            }
            // The service sent the result back in the address (?redirect=<destination>).
            if let destination = browser.handedBack.last, !Self.isSameLocker(destination, link),
               !(destination.host().map { isService($0.lowercased()) } ?? true) {
                return .result(destination)
            }
            if let current = browser.currentURL,
               let value = URLComponents(url: current, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "redirect" })?.value,
               let destination = URL(string: value), ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
               !Self.isSameLocker(destination, link) {
                browser.stop()
                return .result(destination)
            }
            // The service went to the destination by itself.
            if let current = browser.currentURL, let host = current.host()?.lowercased(),
               !isService(host), host != origin, !Self.isIgnored(host) {
                return .result(current)
            }
            let candidates = ([page.result].compactMap { $0 } + page.inputs + page.urls + browser.popupURLs.map(\.absoluteString))
                .filter { candidate in
                    guard candidate != link, !baseline.contains(candidate) || candidate == page.result,
                          let host = URL(string: candidate)?.host()?.lowercased() else { return false }
                    return !isService(host) && host != origin && !Self.isIgnored(host)
                }
            if let candidate = candidates.first {
                // Take it when it stays the same for two turns.
                if candidate == lastCandidate, let url = URL(string: candidate) { return .result(url) }
                lastCandidate = candidate
            }
        }
        return .failed("No result in time")
    }

    /// Opens a page in the panel and collects its MEGA links.
    private func collect(at url: URL, job: BypassJob, waitFor seconds: Double, interactive: Bool) async -> [String] {
        guard let browser else { return [] }
        browser.load(url)
        await browser.waitUntilLoaded(timeout: 25)
        var deadline = Date().addingTimeInterval(seconds)
        var lastCount = -1
        while Date() < deadline {
            guard !Task.isCancelled, !skipRequested else { return [] }
            try? await Task.sleep(for: .milliseconds(800))
            guard let page = await browser.scan(resultSelector: nil) else { continue }
            if collectRequested { return page.mega }
            if !page.mega.isEmpty {
                if page.mega.count == lastCount { return page.mega }
                lastCount = page.mega.count
                continue
            }
            if page.captcha, interactive {
                deadline = max(deadline, Date().addingTimeInterval(30))
            }
        }
        return []
    }

    // MARK: Step 2: with you

    private func withYou(_ job: BypassJob, assist: [BypassProvider]) async -> [String] {
        let link = job.target ?? job.link
        let direct = providers.first { if case .direct = $0.kind { return isEnabled($0) } else { return false } }
        let first = providers.filter { $0.withYouOnly && isEnabled($0) && $0.supports(link) }
        let steps = first + assist.filter { !first.contains($0) } + (direct.map { [$0] } ?? [])
        guard !steps.isEmpty else { return [] }
        return await withPanel(job, waiting: "Waits for you: another link is in the panel") {
            waitingForYou = true
            onNeedsYou?(URL(string: job.link)?.host() ?? job.link)
            for provider in steps {
                guard !Task.isCancelled else { return [] }
                self.provider = provider
                skipRequested = false
                collectRequested = false
                switch provider.kind {
                case .direct:
                    guard let url = URL(string: link) else { continue }
                    job.status = .needsYou("Do the steps of the page in the panel, then press Collect Now")
                    let links = await collect(at: url, job: job, waitFor: 300, interactive: true)
                    job.attempts.append("The page itself: \(links.count) MEGA link(s)")
                    if !links.isEmpty { return links }
                default:
                    job.status = .needsYou("Solve the check of \(provider.name) in the panel")
                    switch await viaPage(provider, link: link, job: job, interactive: true) {
                    case let .mega(links):
                        return links
                    case let .result(url):
                        var more: [BypassProvider] = []
                        let links = await follow(url, job: job, depth: 1, assist: &more)
                        if !links.isEmpty { return links }
                    case let .failed(reason):
                        job.attempts.append("\(provider.name) with you: \(reason)")
                    case .needsYou:
                        break
                    }
                }
            }
            return []
        } ?? []
    }

    private static func isIgnored(_ host: String) -> Bool {
        LinkSorter.matches(host, ignoredHosts)
    }
}

private struct TimeoutError: Error {}

/// Runs work with a time limit.
private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CancellationError() }
        return value
    }
}

/// The private web view of Bypass: no stored cookies or history, no pop-ups,
/// no downloads, only web addresses.
final class BypassBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private(set) var popupURLs: [URL] = []
    /// Destinations that a page handed back in an address (?redirect=<destination>).
    private(set) var handedBack: [URL] = []

    struct PageScan: Decodable {
        let mega: [String]
        let urls: [String]
        let inputs: [String]
        let result: String?
        let captcha: Bool

        var allLinks: [String] { urls + inputs }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    var currentURL: URL? { webView.url }

    func load(_ url: URL) {
        popupURLs = []
        handedBack = []
        webView.load(URLRequest(url: url))
    }

    func stop() {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func waitUntilLoaded(timeout: Double) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while webView.isLoading, Date() < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func scan(resultSelector: String?) async -> PageScan? {
        let json = try? await webView.callAsyncJavaScript(Self.scanScript, arguments: ["resultSelector": resultSelector ?? ""],
                                                          in: nil, contentWorld: .page) as? String
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PageScan.self, from: data)
    }

    func fill(link: String, input: String, submit: String?) async -> String {
        let state = try? await webView.callAsyncJavaScript(Self.fillScript,
                                                           arguments: ["link": link, "inputSelector": input, "submitSelector": submit ?? ""],
                                                           in: nil, contentWorld: .page) as? String
        return state ?? "error"
    }

    // MARK: Policies

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .cancel }
        // Keep a destination handed back in the address; the locker page itself is not needed.
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url,
           let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "redirect" })?.value,
           let destination = URL(string: value), ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
           destination.host() != url.host() {
            handedBack.append(destination)
            return .cancel
        }
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .allow }
        return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    /// Pop-ups do not open; their address can be the result.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            popupURLs.append(url)
        }
        return nil
    }

    // MARK: Scripts

    private static let scanScript = #"""
    const megaRe = /https?:\/\/(?:www\.)?mega\.(?:nz|co\.nz|app|io)\/(?:(?:file|folder)\/[A-Za-z0-9_-]+(?:#[A-Za-z0-9_-]+)?(?:\/(?:file|folder)\/[A-Za-z0-9_-]+)?|#[!FP]*![A-Za-z0-9_!-]+)/gi;
    const urls = new Set(), inputs = new Set();
    for (const a of document.querySelectorAll('a[href]')) { if (/^https?:/i.test(a.href)) urls.add(a.href); }
    for (const i of document.querySelectorAll('input, textarea')) {
      const v = (i.value || '').trim();
      if (/^https?:\/\//i.test(v)) inputs.add(v);
    }
    const text = document.body ? document.body.innerText : '';
    for (const m of (text.match(/https?:\/\/[^\s"'<>]+/g) || [])) urls.add(m);
    const all = [...urls, ...inputs].join('\n') + '\n' + text;
    const mega = [...new Set(all.match(megaRe) || [])];
    let result = null;
    if (resultSelector) {
      const el = document.querySelector(resultSelector);
      if (el) { const v = (el.value || el.href || el.textContent || '').trim(); if (/^https?:\/\//i.test(v)) result = v; }
    }
    // Turnstile can be in a closed shadow root: its empty response field shows it.
    const unsolved = ['cf-turnstile-response', 'h-captcha-response', 'g-recaptcha-response']
      .some(n => [...document.getElementsByName(n)].some(e => !e.value));
    const captcha = unsolved || !!document.querySelector('iframe[src*="hcaptcha"], iframe[src*="challenges.cloudflare"], iframe[src*="recaptcha"], .cf-turnstile, .h-captcha, .g-recaptcha, #challenge-form, #challenge-running');
    return JSON.stringify({ mega, urls: [...urls], inputs: [...inputs], result, captcha });
    """#

    private static let fillScript = #"""
    const input = document.querySelector(inputSelector);
    if (!input) return 'no-input';
    if (input.value !== link) {
      const proto = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(input, link);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }
    let button = null;
    if (submitSelector) {
      for (const b of document.querySelectorAll(submitSelector)) { if (b.offsetParent !== null) { button = b; break; } }
    }
    if (!button && input.form) button = input.form.querySelector('button[type=submit], button:not([type]), input[type=submit]');
    if (button) { if (button.disabled) return 'disabled'; button.click(); return 'clicked'; }
    if (input.form) { input.form.requestSubmit(); return 'submitted'; }
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
    return 'enter';
    """#
}
