import SwiftUI
import MEGABridge

struct SyncView: View {
    @Environment(AppModel.self) private var app
    @State private var adding: MGSyncType?
    @State private var confirmRemove: MGSyncInfo?

    private var center: SyncCenter { app.syncs }

    var body: some View {
        List {
            if center.syncs.isEmpty {
                ContentUnavailableView {
                    Label("No Syncs or Backups", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("A sync keeps a folder on this Mac and a folder in MEGA the same, in both directions. A backup copies a Mac folder to MEGA in one direction.")
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            let twoWay = center.syncs.filter { $0.type == .twoWay }
            let backups = center.syncs.filter { $0.type == .backup }
            if !twoWay.isEmpty {
                Section("Syncs") {
                    ForEach(twoWay, id: \.backupId) { row($0) }
                }
            }
            if !backups.isEmpty {
                Section("Backups") {
                    ForEach(backups, id: \.backupId) { row($0) }
                }
            }
            if !center.stalls.isEmpty {
                Section("Issues") {
                    ForEach(Array(center.stalls.enumerated()), id: \.offset) { _, stall in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(stall.reasonDescription, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            ForEach(stall.localPaths + stall.cloudPaths, id: \.self) { path in
                                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Sync & Backup")
        .navigationSubtitle(center.isStalled ? "Some items need your attention" : center.isSyncing ? "Syncing" : "Up to date")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { adding = .twoWay } label: { Label("Add Sync", systemImage: "plus") }
                    .help("Sync a folder in both directions")
                Button { adding = .backup } label: { Label("Add Backup", systemImage: "externaldrive.badge.plus") }
                    .help("Back up a folder to MEGA")
            }
        }
        .onAppear { center.reload() }
        .sheet(item: $adding) { type in
            AddSyncSheet(type: type)
        }
        .confirmationDialog("Stop this \(confirmRemove?.type == .backup ? "backup" : "sync")?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                guard let sync = confirmRemove else { return }
                Task {
                    do { try await center.remove(sync) } catch { app.show(error) }
                }
            }
        } message: {
            Text("The files stay on this Mac and in MEGA. Only the connection is removed.")
        }
    }

    private func row(_ sync: MGSyncInfo) -> some View {
        let stats = center.stats[sync.backupId]
        let running = sync.runState == .running
        return HStack(spacing: 12) {
            Image(systemName: sync.type == .backup ? "externaldrive.badge.timemachine" : "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(sync.error != 0 ? .red : running ? Color.megaRed : .secondary)
                .symbolEffect(.rotate, isActive: stats?.syncing == true)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(sync.name).font(.headline)
                Label(sync.localPath, systemImage: "laptopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(sync.remotePath.isEmpty ? "MEGA" : sync.remotePath, systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SyncCenter.describe(sync, stats: stats))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(sync.error != 0 ? .red : .primary)
            }
            Spacer()
            Button {
                Task {
                    do { try await center.setRunning(sync, !running) } catch { app.show(error) }
                }
            } label: {
                Image(systemName: running ? "pause.circle" : "play.circle")
            }
            .buttonStyle(.plain)
            .font(.title2)
            .help(running ? "Pause" : "Resume")
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.open(URL(filePath: sync.localPath))
            }
            if sync.remoteHandle != invalidHandle {
                Button("Show in MEGA") { app.revealRequest = sync.remoteHandle }
            }
            Button("Rescan") { center.rescan(sync) }
            Divider()
            Button("Remove…", role: .destructive) { confirmRemove = sync }
        }
    }
}

extension MGSyncType: @retroactive Identifiable {
    public var id: Int { rawValue }
}

private struct AddSyncSheet: View {
    let type: MGSyncType
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var local: URL?
    @State private var remote: UInt64?
    @State private var remoteName = ""
    @State private var choosingRemote = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(type == .backup ? "Add Backup" : "Add Sync").font(.headline)
            Text(type == .backup
                 ? "The folder is copied to Backups in MEGA. Changes in MEGA do not change your Mac."
                 : "Changes in either folder go to the other folder.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("Folder on this Mac") {
                HStack {
                    Text(local?.path ?? "None")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(local == nil ? .secondary : .primary)
                    Button("Choose…", action: chooseLocal)
                }
            }
            if type == .twoWay {
                LabeledContent("Folder in MEGA") {
                    HStack {
                        Text(remote == nil ? "None" : remoteName)
                            .lineLimit(1)
                            .foregroundStyle(remote == nil ? .secondary : .primary)
                        Button("Choose…") { choosingRemote = true }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await add() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(type == .backup ? "Back Up" : "Sync") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || local == nil || (type == .twoWay && remote == nil))
            }
        }
        .padding(22)
        .frame(width: 520)
        .sheet(isPresented: $choosingRemote) {
            FolderPicker(title: "Choose a Folder in MEGA", action: "Choose", exclude: []) { handle in
                remote = handle
                let sdk = app.engine.sdk
                remoteName = sdk.node(forHandle: handle).flatMap { sdk.nodePath(for: $0) } ?? "Folder"
            }
        }
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { local = panel.url }
    }

    private func add() async {
        guard let local else { return }
        busy = true
        defer { busy = false }
        do {
            try await app.syncs.add(type: type, localFolder: local, remoteFolder: remote, name: nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
