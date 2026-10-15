import SwiftUI

struct MenuBarIcon: View {
    let app: AppModel

    var body: some View {
        let symbol: String = if app.syncs.isStalled {
            "exclamationmark.icloud"
        } else if app.transfers.hasActivity || app.syncs.isSyncing {
            "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        } else {
            "icloud"
        }
        Image(systemName: symbol)
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "icloud.fill").foregroundStyle(Color.megaRed)
                Text("MegaGlass").font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            if app.transfers.hasActivity {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        SpeedSlot(symbol: "arrow.down", bytesPerSecond: app.transfers.downloadSpeed)
                        SpeedSlot(symbol: "arrow.up", bytesPerSecond: app.transfers.uploadSpeed)
                    }
                    .font(.caption.monospacedDigit())
                    ForEach(app.transfers.active.prefix(4)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            ProgressView(value: item.progress).controlSize(.small)
                        }
                    }
                    if app.transfers.activeCount > 4 {
                        Text("and \(app.transfers.activeCount - 4) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .glassPanel(cornerRadius: 14)
            }

            if !app.syncs.syncs.isEmpty {
                Label("\(app.syncs.syncs.count) syncs and backups · \(app.syncs.isStalled ? "need attention" : app.syncs.isSyncing ? "syncing" : "up to date")",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }

            if let account = app.session.account {
                VStack(alignment: .leading, spacing: 4) {
                    UsageBar(fraction: account.storageFraction)
                    Text("\(Format.bytes(account.storageUsed)) of \(Format.bytes(account.storageMax))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Open MegaGlass") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.glassProminent)
                if app.transfers.hasActivity || app.transfers.isPaused {
                    Button(app.transfers.isPaused ? "Resume" : "Pause") { app.transfers.togglePauseAll() }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.glass)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var status: String {
        if app.syncs.isStalled { return "Needs attention" }
        if app.transfers.hasActivity { return "\(app.transfers.activeCount) transfers" }
        if app.syncs.isSyncing { return "Syncing" }
        return app.session.isSignedIn ? "Up to date" : "Logged out"
    }
}
