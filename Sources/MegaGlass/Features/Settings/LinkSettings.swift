import SwiftUI

/// How links from the browser and other apps come into MegaGlass.
struct LinkSettings: View {
    @Environment(AppModel.self) private var app
    @State private var isDefault = BrowserRouter.isDefaultBrowser
    @State private var browsers = BrowserRouter.browsers()

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Open copied MEGA and protector links", isOn: $settings.clipboardWatch)
                    .onChange(of: settings.clipboardWatch) { _, enabled in app.clipboard.setEnabled(enabled) }
                Text("Copy a link in any app (for example right-click > Copy Link in the browser). The check is on this Mac; other text, and items that password managers mark as secret, are ignored. Protector links go to Bypass, which sends them to the enabled services. macOS asks once for permission to paste from other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Clipboard")
            }

            Section {
                LabeledContent("MegaGlass is the default browser", value: isDefault ? "Yes" : "No")
                Picker("Other links open in", selection: $settings.forwardBrowser) {
                    Text("Automatic").tag("")
                    ForEach(browsers, id: \.self) { browser in
                        Text(BrowserRouter.name(of: browser)).tag(browser.path)
                    }
                }
                HStack {
                    Spacer()
                    Button("Open Desktop & Dock Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                    }
                }
                Text("Like magnet links for a torrent app: set MegaGlass as the default web browser in Desktop & Dock. Then MEGA links that you click in other apps (Telegram, Mail, Discord) open here, and every other link goes on to the browser above at once. Links that you click inside the browser stay in the browser; use the clipboard for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Links from other apps")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            BrowserRouter.rememberDefault(in: app.settings)
            isDefault = BrowserRouter.isDefaultBrowser
            browsers = BrowserRouter.browsers()
        }
    }
}

/// The services of the all-in-one bypass, in order.
struct BypassSettings: View {
    @Environment(AppModel.self) private var app
    @State private var hosts = ""

    private var center: BypassCenter { app.bypass }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                ForEach(Array(center.providers.enumerated()), id: \.element.id) { index, provider in
                    HStack {
                        Toggle(isOn: Binding(get: { !settings.bypassDisabled.contains(provider.id) },
                                             set: { center.setEnabled(provider, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                Text(provider.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { center.move(provider, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { center.move(provider, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == center.providers.count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Services, in order")
            } footer: {
                Text("First the app reads the link itself: short links, mirror domains and pastes need no service. Then the API services run in order; each one starts when those before it fail or give no answer in 5 seconds. Then the web pages, one at a time, in a hidden private web view for each link. Pages with hCaptcha, and all pages for Admaven lockers, wait for you at the end. Up to 4 links run at the same time; a link that waits for you does not count, and only those links take turns in the panel. The web views have no stored cookies, no pop-ups and no downloads.")
            }

            Section {
                ForEach(center.providers.filter(\.needsKey)) { provider in
                    KeyField(provider: provider)
                }
                Text("Optional. With a key, the service answers directly, with no web page and no captcha. Keys are stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("API keys")
            }

            Section {
                Toggle("Block ads and pop-up networks", isOn: $settings.bypassBlockAds)
                    .onChange(of: settings.bypassBlockAds) { center.applyAdBlocking() }
                Text("In the web pages of Bypass. Pages load faster, and an ad cannot pass for a result. Some lockers do not work with an ad blocker: then turn this off, also from the shield button of the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Web pages")
            }

            Section {
                Toggle("Open found MEGA links automatically", isOn: $settings.bypassAutoOpen)
                Picker("When a link gives more MEGA links, open", selection: $settings.bypassKeepLargest) {
                    Text("All").tag(0)
                    Text("The largest").tag(1)
                    ForEach(2...5, id: \.self) { Text("The \($0) largest").tag($0) }
                }
                Text("Largest: the file, or the folder with all its subfolders. The app asks MEGA for the size of each link before it opens them. To open all the links of a result, right-click it > Open All MEGA Links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $hosts)
                    .font(.callout.monospaced())
                    .frame(height: 110)
                    .onChange(of: hosts) { _, value in
                        settings.protectorHosts = value.split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                    }
                HStack {
                    Text("Link-protector domains, one for each line. Copied or dropped links from these domains go to Bypass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { hosts = LinkSorter.defaultProtectorHosts.joined(separator: "\n") }
                }
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hosts = settings.protectorHosts.joined(separator: "\n")
        }
    }
}

private struct KeyField: View {
    let provider: BypassProvider
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var saved = false
    @State private var readError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(provider.name, text: $key)
                    .onSubmit(save)
                Button(saved ? "Saved" : "Save", action: save)
                    .disabled(key.isEmpty)
                Button("Remove") {
                    // The field clears only when the key is really gone.
                    guard app.bypass.setKey(nil, for: provider) else { return }
                    key = ""
                    saved = false
                    readError = nil
                }
            }
            if let readError {
                Text("The Keychain did not give the saved key, so this service is off. \(readError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            do {
                key = try app.bypass.loadKey(for: provider) ?? ""
                readError = nil
            } catch {
                readError = error.localizedDescription
            }
        }
    }

    private func save() {
        saved = app.bypass.setKey(key, for: provider)
        if saved { readError = nil }
    }
}
