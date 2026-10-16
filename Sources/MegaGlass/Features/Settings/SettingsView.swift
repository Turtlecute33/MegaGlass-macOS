import MEGABridge
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TransferSettings()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            LinkSettings()
                .tabItem { Label("Links", systemImage: "link") }
            BypassSettings()
                .tabItem { Label("Bypass", systemImage: "wand.and.sparkles") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 580)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text(settings.downloadFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url }
                    }
                }
            }
            Toggle("Ask where to save each download", isOn: $settings.askWhereToDownload)
            Toggle("Show in the menu bar", isOn: $settings.showMenuBarExtra)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        app.show(error, title: "The login item was not changed")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Text("Syncs and transfers keep running when you close the window while the app is in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TransferSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Stepper(value: $settings.downloadConnections, in: 1...32) {
                    LabeledContent("Download connections per file", value: "\(settings.downloadConnections)")
                }
                Stepper(value: $settings.uploadConnections, in: 1...32) {
                    LabeledContent("Upload connections per file", value: "\(settings.uploadConnections)")
                }
                Text("MEGA splits each file into chunks and moves them in parallel. 8 is the desktop default. More connections can help on fast, long-distance links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                limitField("Download limit", value: $settings.downloadLimitKB)
                limitField("Upload limit", value: $settings.uploadLimitKB)
            }
            Section {
                Stepper(value: $settings.workerThreads, in: 1...8) {
                    LabeledContent("Encryption threads", value: "\(settings.workerThreads)")
                }
                Text("Threads that encrypt, decrypt and verify chunks with the hardware AES unit. Applies after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: settings.downloadConnections) { app.transfers.applyLimits(settings) }
        .onChange(of: settings.uploadConnections) { app.transfers.applyLimits(settings) }
        .onChange(of: settings.downloadLimitKB) { app.transfers.applyLimits(settings) }
        .onChange(of: settings.uploadLimitKB) { app.transfers.applyLimits(settings) }
    }

    private func limitField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", value: value, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text("KB/s (0 = no limit)").foregroundStyle(.secondary)
            }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Text("Files are encrypted on this Mac before upload and decrypted after download. MEGA cannot read them.")
            Text("MegaGlass adds no telemetry or analytics. Cloud storage uses the MEGA SDK, which sends MEGA short diagnostic reports: load times and item counts each time the account or a folder link loads, and error events (for example a file that cannot be decrypted, or a sync or database problem).")
            Text("Bypass: the app opens each protector link and its result pages itself, from your internet address. It sends the link, and each link that a locker gives back (not the MEGA links), to the enabled third-party services and loads their pages; their privacy policies apply. Links from the clipboard watch and from the browser router go to Bypass with no other step. The izen.lol page gets your izen.lol key in its address. Bypass blocks the addresses of this Mac and of your local network by number or by local name (such as .local). It cannot block a public name that points to them.")
            Text("Copied MEGA links stay on this Mac: they do not go to other devices (Universal Clipboard) or to clipboard history apps.")
            LabeledContent("Hardware AES", value: MGDiagnostics.hasHardwareAES ? "Active" : "Not available")
            LabeledContent("Cached thumbnails and previews") {
                Button("Clear Cache") {
                    app.engine.thumbnails.clear()
                    for link in app.links.sessions {
                        link.engine?.thumbnails.clear()
                        link.fileThumbnails?.clear()
                    }
                    app.notify("Cache cleared", symbol: "trash")
                }
            }
        }
    }
}
