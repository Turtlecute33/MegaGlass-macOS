import SwiftUI
import WebKit

struct BypassView: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""

    private var center: BypassCenter { app.bypass }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                input
                jobList
            }
            .frame(width: 340)
            .padding(12)

            panel
                .padding([.vertical, .trailing], 12)
        }
        .navigationTitle("Bypass")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { center.clearFinished() } label: { Label("Clear Finished", systemImage: "checkmark.circle.badge.xmark") }
                    .help("Remove finished links from the list")
                SettingsLink { Label("Services", systemImage: "slider.horizontal.3") }
                    .help("Choose and order the bypass services")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.handleIncoming(urls.map(\.absoluteString).joined(separator: "\n"), source: .drop, forceBypass: true)
            return true
        }
    }

    private var subtitle: String {
        let waiting = center.jobs.filter { !$0.isFinished }.count
        return waiting == 0 ? "Idle" : "\(waiting) in queue"
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste protected or shortened links. Each link goes through the services in order, then the MEGA links open here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            HStack {
                PasteLinesButton(text: $text)
                Spacer()
                Button {
                    app.handleIncoming(text, source: .paste, forceBypass: true)
                    text = ""
                } label: {
                    Label("Resolve", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.glassProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Links are sent to the enabled services (\(center.providers.filter { center.isEnabled($0) && $0.kind != .direct }.map(\.name).joined(separator: ", "))). You are asked only if they all fail.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassPanel(cornerRadius: 18)
    }

    private var jobList: some View {
        List {
            ForEach(center.jobs.reversed()) { job in
                JobRow(job: job)
                    .contextMenu {
                        if !job.megaLinks.isEmpty {
                            let keep = app.settings.bypassKeepLargest
                            if keep > 0, job.megaLinks.count > keep {
                                Button(keep == 1 ? "Open the Largest MEGA Link" : "Open the \(keep) Largest MEGA Links") { center.openLinks(of: job) }
                                Button("Open All \(job.megaLinks.count) MEGA Links") { center.openLinks(of: job, all: true) }
                            } else {
                                Button("Open MEGA Links") { center.openLinks(of: job) }
                            }
                            Button("Copy MEGA Links") { Pasteboard.copy(job.megaLinks.joined(separator: "\n")) }
                        }
                        if job.isFinished { Button("Try Again") { center.retry(job) } }
                        Button("Copy Original Link") { Pasteboard.copy(job.link) }
                        Button("Remove", role: .destructive) { center.remove(job) }
                    }
            }
        }
        .listStyle(.inset)
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            if center.jobs.isEmpty {
                ContentUnavailableView("No Links", systemImage: "link.badge.plus",
                                       description: Text("Paste links above, or drop them here."))
            }
        }
    }

    /// Ads on or off in the web pages; the page of the panel loads again.
    private var adToggle: some View {
        @Bindable var settings = app.settings
        return Toggle(isOn: $settings.bypassBlockAds) {
            Image(systemName: settings.bypassBlockAds ? "shield.lefthalf.filled" : "shield.slash")
        }
        .toggleStyle(.button)
        .help(settings.bypassBlockAds ? "Ads are blocked. Click to allow them (for a locker that needs them)." : "Ads are allowed. Click to block them.")
        .onChange(of: settings.bypassBlockAds) { center.applyAdBlocking(reloadPanel: true) }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let job = center.current {
                    Image(systemName: job.status.symbol)
                        .foregroundStyle(job.status.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(center.provider?.name ?? "Bypass").font(.headline)
                        Text(job.status.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    adToggle
                    Button("Collect Now") { center.collectNow() }
                        .help("Take the MEGA links that the page shows now")
                    Button("Next Service") { center.skipService() }
                    Button(role: .cancel) { center.cancelCurrent() } label: { Text("Stop") }
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                    Text("Services run by themselves. This panel needs you only if they all fail.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    adToggle
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(12)

            Group {
                if let browser = center.browser {
                    WebPanel(webView: browser.webView)
                } else {
                    Color.clear
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            .padding([.horizontal, .bottom], 8)
        }
        .glassPanel(cornerRadius: 20)
    }
}

private struct JobRow: View {
    let job: BypassJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if case .running = job.status {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: job.status.symbol).foregroundStyle(job.status.tint)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.link)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !job.attempts.isEmpty {
                    DisclosureGroup("\(job.attempts.count) step(s)") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(job.attempts.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

extension BypassJob.Status {
    var text: String {
        switch self {
        case .waiting: "Waiting"
        case let .running(step): step
        case let .needsYou(message): message
        case let .done(count): count == 1 ? "1 MEGA link found" : "\(count) MEGA links found"
        case let .failed(reason): reason
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .needsYou: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: .orange
        case .done: .green
        case .failed: .red
        default: .secondary
        }
    }
}

/// Hosts the shared WKWebView of Bypass.
private struct WebPanel: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
