import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "All", downloads = "Downloads", uploads = "Uploads", finished = "Finished"
    }

    private var transfers: TransferCenter { app.transfers }

    private var shown: [TransferItem] {
        switch filter {
        case .all: transfers.items.filter { !$0.isFinished } + transfers.items.filter(\.isFinished).reversed()
        case .downloads: transfers.items.filter { $0.isDownload && !$0.isFinished }
        case .uploads: transfers.items.filter { !$0.isDownload && !$0.isFinished }
        case .finished: transfers.items.filter(\.isFinished).reversed()
        }
    }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Downloads and uploads show here."))
            } else {
                List(shown) { item in
                    TransferRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Transfers")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    transfers.togglePauseAll()
                } label: {
                    Label(transfers.isPaused ? "Resume All" : "Pause All",
                          systemImage: transfers.isPaused ? "play.fill" : "pause.fill")
                }
                .help(transfers.isPaused ? "Resume all transfers" : "Pause all transfers")
                Button {
                    transfers.clearFinished()
                } label: {
                    Label("Clear Finished", systemImage: "checkmark.circle.badge.xmark")
                }
                .help("Remove finished transfers from the list")
                Button(role: .destructive) {
                    transfers.cancelAll()
                } label: {
                    Label("Cancel All", systemImage: "xmark.circle")
                }
                .help("Cancel all transfers")
                .disabled(!transfers.hasActivity)
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(transfers.activeCount) active"]
        if transfers.downloadSpeed > 0 { parts.append("↓ " + Format.speed(transfers.downloadSpeed)) }
        if transfers.uploadSpeed > 0 { parts.append("↑ " + Format.speed(transfers.uploadSpeed)) }
        return parts.joined(separator: " · ")
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var app
    let item: TransferItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                Image(systemName: item.isDownload ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, item.isDownload ? Color.blue : Color.megaRed)
                    .font(.system(size: 13))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.isFinished {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(item.state == .paused ? .secondary : .megaRed)
                }
                HStack {
                    Text(item.statusText)
                        .foregroundStyle(item.state == .failed ? .red : .secondary)
                    Spacer()
                    Text(item.isFinished ? Format.bytes(item.totalBytes)
                         : "\(Format.bytes(item.transferredBytes)) of \(Format.bytes(item.totalBytes))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
            }
            actions
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !item.isFinished {
                Button(item.state == .paused ? "Resume" : "Pause") { app.transfers.pause(item, item.state != .paused) }
                Button("Move to Top") { app.transfers.moveToTop(item) }
                Button("Cancel", role: .destructive) { app.transfers.cancel(item) }
            } else {
                if item.isDownload, item.state == .complete {
                    Button("Show in Finder") { app.transfers.reveal(item) }
                }
                if !item.isDownload, item.state == .complete {
                    Button("Show in MEGA") { app.revealRequest = item.parentHandle }
                }
                if item.state == .failed {
                    Button("Retry") { app.transfers.retry(item) }
                }
                Button("Remove from List") { app.transfers.remove(item) }
            }
        }
    }

    private var icon: NSImage {
        FileIcons.icon(name: item.name, isFolder: item.isFolder)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if !item.isFinished {
                Button {
                    app.transfers.pause(item, item.state != .paused)
                } label: {
                    Image(systemName: item.state == .paused ? "play.circle" : "pause.circle")
                }
                .help(item.state == .paused ? "Resume" : "Pause")
                Button {
                    app.transfers.cancel(item)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Cancel")
            } else if item.state == .failed {
                Button { app.transfers.retry(item) } label: { Image(systemName: "arrow.clockwise.circle") }
                    .help("Retry")
            } else if item.isDownload, item.state == .complete {
                Button { app.transfers.reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
}
