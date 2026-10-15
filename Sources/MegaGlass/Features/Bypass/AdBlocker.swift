import Foundation
import WebKit

/// Blocks the ad, pop-up and tracking networks in the Bypass web views (WebKit content
/// rules, compiled once). Captchas, Cloudflare checks and the bypass services are not on
/// the list. Some lockers refuse to work with an ad blocker: Settings > Bypass turns it off.
enum AdBlocker {
    /// A new list needs a new identifier.
    private static let identifier = "megaglass-ads-1"
    private static var compiled: WKContentRuleList?

    static func rules(store: WKContentRuleListStore? = .default()) async -> WKContentRuleList? {
        if let compiled { return compiled }
        guard let store else { return nil }
        if let found = try? await store.contentRuleList(forIdentifier: identifier) {
            compiled = found
            return found
        }
        compiled = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: ruleJSON)
        return compiled
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
