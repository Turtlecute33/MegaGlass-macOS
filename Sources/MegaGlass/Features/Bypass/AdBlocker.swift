import Foundation
import WebKit

/// Blocks the ad, pop-up and tracking networks in the Bypass web views (WebKit content
/// rules, compiled once). Captchas, Cloudflare checks and the bypass services are not on
/// the list. Some lockers refuse to work with an ad blocker: Settings > Bypass turns it off.
enum AdBlocker {
    /// A new list needs a new identifier.
    private static let identifier = "megaglass-ads-1"
    private static let localIdentifier = "megaglass-local-2"
    private static var compiled: WKContentRuleList?
    /// The rules for the addresses of this Mac and the local network, once compiled. The
    /// Bypass web views always have them: they also block the requests of a page (scripts,
    /// images, fetch, WebSocket), not only its navigations.
    private(set) static var localRules: WKContentRuleList?

    static func rules(store: WKContentRuleListStore? = .default()) async -> WKContentRuleList? {
        if let compiled { return compiled }
        compiled = await list(identifier, json: ruleJSON, store: store)
        return compiled
    }

    static func loadLocalRules(store: WKContentRuleListStore? = .default()) async -> WKContentRuleList? {
        if let localRules { return localRules }
        localRules = await list(localIdentifier, json: localRuleJSON, store: store)
        return localRules
    }

    private static func list(_ identifier: String, json: String, store: WKContentRuleListStore?) async -> WKContentRuleList? {
        guard let store else { return nil }
        if let found = try? await store.contentRuleList(forIdentifier: identifier) { return found }
        return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
    }

    /// Hosts of this Mac and of the local network, as WebKit writes them (numbers in the
    /// dotted form, IPv6 in short form). WebKit rules have no "|": one rule for each form.
    static let localHosts = [
        // Names with no dot (localhost, router, router.), and local name suffixes
        #"[^\[:/.@]+\.?"#, #"localhost\."#, #"[^:/]+\.local\.?"#, #"[^:/]+\.localhost\.?"#, #"[^:/]+\.internal\.?"#,
        #"[^:/]+\.lan\.?"#, #"[^:/]+\.home\.arpa\.?"#, #"[^:/]+\.localdomain\.?"#,
        // IPv4: this network, loopback, private, link-local, shared (CGNAT)
        #"0\.[0-9.]+"#, #"127\.[0-9.]+"#, #"10\.[0-9.]+"#, #"192\.168\.[0-9.]+"#, #"169\.254\.[0-9.]+"#,
        #"172\.1[6-9]\.[0-9.]+"#, #"172\.2[0-9]\.[0-9.]+"#, #"172\.3[01]\.[0-9.]+"#,
        #"100\.6[4-9]\.[0-9.]+"#, #"100\.[7-9][0-9]\.[0-9.]+"#, #"100\.1[01][0-9]\.[0-9.]+"#, #"100\.12[0-7]\.[0-9.]+"#,
        // IPv6: unspecified, loopback and mapped IPv4; unique local, link-local, multicast
        #"\[::[0-9a-f:.]*\]"#, #"\[f[c-f][0-9a-f:.]*\]"#,
    ]

    static var localRuleJSON: String {
        // WebKit matches the whole address, also a user name and password before the host.
        let rules: [[String: Any]] = localHosts.map { host in
            ["trigger": ["url-filter": "^[^:]+://+([^/@]*@)?" + host + "[:/]"], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Ad and pop-up networks of locker, paste and bypass pages, and the common ad servers.
    static let hosts = [
        // Google ads and statistics
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "google-analytics.com",
        // Pop-under, push and redirect networks
        "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "onclickads.net", "onclkds.com",
        "onclickalgo.com", "adsterra.com", "adsterratech.com", "highperformanceformat.com", "highcpmrevenuegate.com",
        "profitableratecpmnetwork.com", "effectiveratecpm.com", "profitablegatecpm.com", "a-ads.com", "adcash.com",
        "acscdn.com", "exoclick.com", "exosrv.com", "exdynsrv.com", "magsrv.com", "juicyads.com", "trafficjunky.net",
        "trafficstars.com", "tsyndicate.com", "hilltopads.net", "clickadu.com", "monetag.com", "galaksion.com",
        "clickaine.com", "realsrv.com", "yllix.com", "cpmstar.com", "pubfuture.com", "bidvertiser.com",
        // Ad servers and content recommendation
        "adnxs.com", "criteo.com", "criteo.net", "pubmatic.com", "rubiconproject.com", "openx.net",
        "amazon-adsystem.com", "media.net", "adform.net", "smartadserver.com", "casalemedia.com", "33across.com",
        "sharethrough.com", "lijit.com", "indexww.com", "contextweb.com", "yieldmo.com", "teads.tv", "taboola.com",
        "outbrain.com", "mgid.com", "revcontent.com", "zemanta.com", "adskeeper.com", "adskeeper.co.uk",
        "infolinks.com", "vidoomy.com",
    ]

    static var ruleJSON: String {
        var rules: [[String: Any]] = hosts.map { host in
            [
                "trigger": [
                    "url-filter": "^[^:]+://+([^:/]+\\.)?" + NSRegularExpression.escapedPattern(for: host) + "[:/]",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        // Empty ad boxes of the blocked networks.
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": "ins.adsbygoogle, .adsbygoogle, div[id^='google_ads_'], iframe[id^='google_ads_iframe'], div[id^='div-gpt-ad']",
            ],
        ])
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
