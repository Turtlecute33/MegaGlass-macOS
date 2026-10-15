import Foundation
import Testing
import WebKit
@testable import MegaGlass

/// Offline answers for the HTTP requests of Bypass: the API services and the pages.
/// Nothing goes to the network.
nonisolated final class BypassStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers = ["Content-Type": "text/html"]
        var body = ""

        static func page(_ html: String) -> Reply { Reply(body: html) }
        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"], body: text)
        }
        static func redirect(_ location: String) -> Reply { Reply(status: 302, headers: ["Location": location]) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var route: (@Sendable (_ host: String, _ submitted: String?) -> Reply)?
    nonisolated(unsafe) private static var requests: [String] = []

    static func start(_ route: @escaping @Sendable (_ host: String, _ submitted: String?) -> Reply) {
        lock.withLock {
            self.route = route
            requests = []
        }
    }

    /// "host submitted-link" for the APIs, "host url" for the pages.
    static var log: [String] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host() ?? ""
        let submitted = Self.submittedLink(request)
        let route = Self.lock.withLock { () -> (@Sendable (String, String?) -> Reply)? in
            Self.requests.append(host + " " + (submitted ?? url.absoluteString))
            return Self.route
        }
        let reply = route?(host, submitted) ?? Reply(status: 404)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let location = reply.headers["Location"],
           let next = URL(string: location, relativeTo: url)?.absoluteURL {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The link that a request gives to an API: url= in the query, or "url" in the JSON body.
    private static func submittedLink(_ request: URLRequest) -> String? {
        if let url = request.url, let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value {
            return value
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["url"] as? String
    }
}

nonisolated private let megaFolder = "https://mega.nz/folder/AbCdEfGh#Key-1234567890abcdefghij"
nonisolated private let megaFile = "https://mega.nz/file/XyZ12345#FileKey-0123456789abcdef"

/// A locker → output link chain on the bypass.tools API. Other API hosts fail at once.
nonisolated private func apiChain(_ chain: [String: String]) -> @Sendable (String, String?) -> BypassStub.Reply {
    { host, submitted in
        switch host {
        case "bypasskit.co":
            return .json(#"{"success":false,"message":"Unsupported"}"#)
        case "api.bypass.tools":
            guard let submitted, let result = chain[submitted] else {
                return .json(#"{"status":"error","message":"Unsupported link"}"#, status: 400)
            }
            return .json(#"{"status":"success","result":"\#(result)"}"#)
        default:
            // Locker and shortener pages: no MEGA link in their HTML.
            return .page("<html><body>Please wait… <a href='https://ads.example/x'>Continue</a></body></html>")
        }
    }
}

@MainActor
@Suite(.serialized)
struct BypassChainTests {
    private let suite = "megaglass-bypass-tests-" + UUID().uuidString

    /// API services: BypassKit (keyless) and the bypass.tools API with a fixture key. No web
    /// views and no step 2: the chain logic only.
    private func makeCenter() -> BypassCenter {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.bypassAutoOpen = false
        settings.bypassDisabled = ["rip.linkvertise.lol"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BypassStub.self]
        return BypassCenter(settings: settings, configuration: configuration,
                            keyLookup: { $0 == "bypass.tools-api" ? "fixture-key" : nil }, usesWebViews: false)
    }

    private func run(_ link: String, in center: BypassCenter) async throws -> BypassJob {
        center.enqueue([link])
        let job = try #require(center.jobs.last)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !job.isFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(job.isFinished)
        center.shutdown()
        UserDefaults().removePersistentDomain(forName: suite)
        return job
    }

    private func apiRequests(for link: String) -> Int {
        BypassStub.log.filter { $0 == "api.bypass.tools " + link }.count
    }

    @Test func outputLinkOnAnUnknownShortenerIsBypassedToo() async throws {
        BypassStub.start(apiChain([
            "https://linkvertise.com/1/first": "https://short.example/abc",
            "https://short.example/abc": megaFolder,
        ]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.status == .done(1))
        #expect(job.megaLinks == [megaFolder])
        #expect(job.attempts.contains { $0.contains("short.example goes through the services too") })
    }

    @Test func outputLinkOnAKnownLockerIsBypassedToo() async throws {
        BypassStub.start(apiChain([
            "https://linkvertise.com/1/first": "https://work.ink/2/second",
            "https://work.ink/2/second": megaFile,
        ]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.megaLinks == [megaFile])
        #expect(job.attempts.contains { $0.hasPrefix("Next protector: work.ink") })
    }

    @Test func chainOfThreeLockers() async throws {
        BypassStub.start(apiChain([
            "https://linkvertise.com/1/first": "https://short.example/two",
            "https://short.example/two": "https://other.example/three",
            "https://other.example/three": megaFolder,
        ]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.megaLinks == [megaFolder])
    }

    @Test func shortLinkThatRedirectsToMegaNeedsNoService() async throws {
        BypassStub.start { host, _ in
            host == "bit.example" ? .redirect(megaFile) : .page("<html>MEGA page, not needed</html>")
        }
        let job = try await run("https://bit.example/s1", in: makeCenter())
        #expect(job.megaLinks == [megaFile])
        #expect(!BypassStub.log.contains { $0.hasPrefix("api.bypass.tools") || $0.hasPrefix("bypasskit.co") })
        #expect(!BypassStub.log.contains { $0.hasPrefix("mega.nz") })
    }

    @Test(arguments: [
        // Base64 in the address of a safelink page
        "https://safe.example/go?u=" + Data(megaFile.utf8).base64EncodedString(),
        // Percent-encoded in the address
        "https://safe.example/go?url=" + megaFile.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
    ]) func megaLinkHiddenInTheOutputAddress(output: String) async throws {
        BypassStub.start(apiChain(["https://linkvertise.com/1/first": output]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.megaLinks == [megaFile])
        // Found in the address: the safelink page is not even loaded.
        #expect(!BypassStub.log.contains { $0.hasPrefix("safe.example") })
    }

    @Test func megaLinkInBase64InTheResultPage() async throws {
        let encoded = Data(megaFolder.utf8).base64EncodedString()
        BypassStub.start { host, submitted in
            if host == "paste.example" { return .page("<button data-target='\(encoded)'>Get link</button>") }
            return apiChain(["https://linkvertise.com/1/first": "https://paste.example/p/1"])(host, submitted)
        }
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.megaLinks == [megaFolder])
    }

    @Test func loopOfLockersEnds() async throws {
        BypassStub.start(apiChain([
            "https://linkvertise.com/1/first": "https://short.example/loop",
            "https://short.example/loop": "https://linkvertise.com/1/first",
        ]))
        let start = ContinuousClock.now
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.status == .failed("No MEGA links found"))
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(apiRequests(for: "https://linkvertise.com/1/first") == 1)
    }

    @Test func longChainStopsAtTheDepthLimit() async throws {
        var chain: [String: String] = ["https://linkvertise.com/1/first": "https://hop.example/1"]
        for index in 1..<12 { chain["https://hop.example/\(index)"] = "https://hop.example/\(index + 1)" }
        BypassStub.start(apiChain(chain))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.status == .failed("No MEGA links found"))
        #expect(apiRequests(for: "https://hop.example/8") == 0)
    }

    @Test func socialOrAdResultIsNotBypassed() async throws {
        BypassStub.start(apiChain(["https://linkvertise.com/1/first": "https://t.me/somechannel"]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.isFinished)
        #expect(apiRequests(for: "https://t.me/somechannel") == 0)
    }

    @Test func missingOutputPageIsNotBypassed() async throws {
        BypassStub.start { host, submitted in
            if host == "gone.example" { return BypassStub.Reply(status: 404) }
            return apiChain(["https://linkvertise.com/1/first": "https://gone.example/x"])(host, submitted)
        }
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.isFinished)
        #expect(apiRequests(for: "https://gone.example/x") == 0)
    }

    @Test func sameLockerResultIsIgnored() async throws {
        BypassStub.start(apiChain(["https://linkvertise.com/1/first": "https://linkvertise.com/1/first"]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.status == .failed("No MEGA links found"))
        #expect(job.attempts.contains { $0.contains("only the next redirect of the same locker") })
    }

    @Test func localNetworkResultIsNeverOpened() async throws {
        BypassStub.start(apiChain(["https://linkvertise.com/1/first": "http://192.168.1.1/admin"]))
        let job = try await run("https://linkvertise.com/1/first", in: makeCenter())
        #expect(job.isFinished)
        #expect(!BypassStub.log.contains { $0.hasPrefix("192.168.1.1") })
    }
}

@MainActor
struct AdBlockerTests {
    @Test func megaLinkFinderReadsHiddenLinks() {
        #expect(MegaLinkFinder.links(in: "plain \(megaFile) text") == [megaFile])
        #expect(MegaLinkFinder.links(in: "go?url=" + megaFile.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!) == [megaFile])
        let urlSafe = Data(megaFolder.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        #expect(MegaLinkFinder.links(in: "data-u=\"\(urlSafe)\"") == [megaFolder])
        #expect(MegaLinkFinder.links(in: Data("https://example.com/not-mega".utf8).base64EncodedString()).isEmpty)
    }

    @Test func rulesCompileAndHideAdBoxes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "megaglass-rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A private store: the rules of the app are not touched.
        let rules = try #require(await AdBlocker.rules(store: WKContentRuleListStore(url: folder)))

        let browser = BypassBrowser()
        defer { browser.stop() }
        browser.blockAds(rules)
        browser.webView.loadHTMLString(#"<ins class="adsbygoogle" id="ad">ad</ins><p id="text">text</p>"#,
                                       baseURL: URL(string: "https://page.example/"))
        await browser.waitUntilLoaded(timeout: 10)
        let shown = { (id: String) async -> String? in
            try? await browser.webView.callAsyncJavaScript("return getComputedStyle(document.getElementById(id)).display",
                                                         arguments: ["id": id], in: nil, contentWorld: .page) as? String
        }
        #expect(await shown("ad") == "none")
        #expect(await shown("text") == "block")
    }

    @Test func scanFindsLinksInBase64AndScripts() async throws {
        let browser = BypassBrowser()
        defer { browser.stop() }
        let encoded = Data(megaFolder.utf8).base64EncodedString()
        browser.webView.loadHTMLString("""
            <button onclick="location.href='\(megaFile)'">Download</button>
            <a href="https://safe.example/go?u=\(encoded)">Link</a>
            """, baseURL: URL(string: "https://page.example/"))
        await browser.waitUntilLoaded(timeout: 10)
        let page = try #require(await browser.scan(resultSelector: nil))
        #expect(Set(page.mega) == [megaFile, megaFolder])
    }
}
