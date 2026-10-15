import SwiftUI
@preconcurrency import MEGASdk

struct InspectorView: View {
    let model: BrowserModel
    @Environment(AppModel.self) private var app
    @State private var preview: CGImage?
    @State private var folderInfo: (files: Int, folders: Int, size: Int64, versions: Int)?
    @State private var versionCount = 0
    @State private var path: String?

    private var items: [NodeItem] { model.selectedItems }

    var body: some View {
        ScrollView {
            if items.count == 1, let item = items.first {
                single(item)
            } else if items.count > 1 {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("\(items.count) items").font(.title3.weight(.semibold))
                    Text(Format.bytes(items.reduce(0) { $0 + $1.size }))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
            } else {
                Text("Select an item to see its details.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: items.map(\.id)) { await load() }
    }

    @ViewBuilder
    private func single(_ item: NodeItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    NodeIcon(item: item, store: model.engine.thumbnails, size: 120, cornerRadius: 14)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(item.kind.title + (item.duration > 0 ? " · " + Format.playtime(Double(item.duration)) : "")
                     + (item.isFolder ? "" : " · " + Format.bytes(item.size)))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button { app.download([item.id], from: model.engine) } label: { Label("Download", systemImage: "arrow.down") }
                if model.engine.kind == .account, !model.isRubbish {
                    Button { Task { await app.copyLinks([item.id]) } } label: { Label("Link", systemImage: "link") }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                if let folderInfo {
                    row("Contains", "\(folderInfo.files) files, \(folderInfo.folders) folders")
                    row("Size", Format.bytes(folderInfo.size))
                    if folderInfo.versions > 0 { row("Versions", "\(folderInfo.versions)") }
                } else if !item.isFolder {
                    row("Size", Format.bytes(item.size))
                }
                if item.duration > 0 { row("Length", Format.playtime(Double(item.duration))) }
                row("Modified", Format.date(item.modified))
                row("Created", Format.date(item.created))
                if versionCount > 1 { row("Versions", "\(versionCount)") }
                if let path { row("Where", path) }
                if item.isExported { row("Link", "Public link on") }
                if item.isOutShare { row("Sharing", "Shared with contacts") }
                if item.isInShare { row("Sharing", "Shared with you") }
            }
            .font(.callout)
        }
        .padding(16)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private func load() async {
        preview = nil
        folderInfo = nil
        versionCount = 0
        path = nil
        guard items.count == 1, let item = items.first else { return }
        let engine = model.engine
        let sdk = engine.sdk
        let handle = item.id
        let details = await EngineQueue.run { () -> (String?, Int) in
            guard let node = sdk.node(forHandle: handle) else { return (nil, 0) }
            let parent = sdk.parentNode(for: node).flatMap { sdk.nodePath(for: $0) }
            return (parent, node.isFile() ? sdk.numberOfVersions(for: node) : 0)
        }
        guard !Task.isCancelled else { return }
        path = details.0
        versionCount = details.1
        if item.isFolder {
            guard let node = engine.node(handle),
                  let info = try? await sdk.request({ sdk.getFolderInfo(for: node, delegate: $0) }).megaFolderInfo else { return }
            guard !Task.isCancelled else { return }
            folderInfo = (info.files, info.folders, info.currentSize, info.versions)
        } else if item.hasPreview {
            let image = await engine.thumbnails.preview(handle)
            guard !Task.isCancelled else { return }
            preview = image
        }
    }
}
