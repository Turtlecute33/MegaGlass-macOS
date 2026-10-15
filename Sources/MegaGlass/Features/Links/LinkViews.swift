import SwiftUI
@preconcurrency import MEGASdk

/// Paste one or many links; each one opens in its own session.
struct OpenLinksSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var found: Int {
        let sorted = LinkSorter.sort(text, protectorHosts: Set(app.settings.protectorHosts))
        return sorted.mega.count + sorted.protected.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open MEGA Links").font(.headline)
            Text("Paste file or folder links. Each link opens on its own, and many can be open at the same time. Link-protector links go to Bypass.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(width: 520, height: 160)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            HStack {
                Button("Paste") {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        text += (text.isEmpty ? "" : "\n") + value
                    }
                }
                Text(found == 1 ? "1 link" : "\(found) links")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Cancel", role: .cancel) {
                    if app.links.sessions.isEmpty, !app.session.isSignedIn { app.session.isGuest = false }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open") {
                    app.handleIncoming(text, source: .paste)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(found == 0)
            }
        }
        .padding(22)
    }
}

struct LinkDetailView: View {
    let session: LinkSession
    @Environment(AppModel.self) private var app

    var body: some View {
        switch session.state {
        case .opening:
            VStack(spacing: 12) {
                ProgressView()
                Text("Decrypting link…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsPassword:
            LinkPasswordView(session: session)
        case let .failed(message):
            ContentUnavailableView {
                Label("The Link Did Not Open", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    // In the task that Close Link cancels; a second click does nothing.
                    session.beginOpen(using: app.engine, workerThreads: app.settings.workerThreads)
                }
                Button("Close Link") { app.links.close(session) }
            }
        case .ready:
            if let browser = session.browser {
                BrowserView(model: browser)
                    .id(session.id)
            } else if let node = session.fileNode, let item = session.fileItem {
                FileLinkView(session: session, node: node, item: item)
            }
        }
    }
}

private struct LinkPasswordView: View {
    let session: LinkSession
    @Environment(AppModel.self) private var app
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("This link is protected with a password.").font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(unlock)
            Button("Decrypt", action: unlock)
                .buttonStyle(.glassProminent)
                .disabled(password.isEmpty)
        }
        .padding(32)
        .glassPanel(cornerRadius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        Task { await session.unlock(password: password, using: app.engine, workerThreads: app.settings.workerThreads) }
    }
}

private struct FileLinkView: View {
    let session: LinkSession
    let node: MEGANode
    let item: NodeItem
    @Environment(AppModel.self) private var app
    @State private var preview: CGImage?
    @State private var importing = false

    var body: some View {
        VStack(spacing: 20) {
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 16))
                        .frame(maxWidth: 420, maxHeight: 300)
                } else {
                    NodeIcon(item: item, store: app.engine.thumbnails, node: node, size: 128)
                }
            }
            VStack(spacing: 4) {
                Text(item.name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text([item.kind.title, item.duration > 0 ? Format.playtime(Double(item.duration)) : nil,
                      Format.bytes(item.size)].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        app.download(publicNode: node)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.glassProminent)
                    if app.session.isSignedIn {
                        Button {
                            importing = true
                        } label: {
                            Label("Import to Cloud Drive", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(36)
        .glassPanel(cornerRadius: 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(item.name)
        .task {
            if item.hasPreview {
                preview = await app.engine.thumbnails.preview(item.id, node: node)
            }
        }
        .sheet(isPresented: $importing) {
            FolderPicker(title: "Import to Cloud Drive", action: "Import", exclude: []) { folder in
                Task { await app.importPublicNode(node, to: folder) }
            }
        }
    }
}
