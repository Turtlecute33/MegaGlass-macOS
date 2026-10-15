import SwiftUI
@preconcurrency import MEGASdk

extension Color {
    static let megaRed = Color(red: 0.851, green: 0.0, blue: 0.027)
}

/// File icon or thumbnail. A known thumbnail draws in the first frame; others load
/// on a background task and are dropped when the cell scrolls away.
struct NodeIcon: View {
    let item: NodeItem
    let store: ThumbnailStore
    var node: MEGANode?
    var size: CGFloat
    var cornerRadius: CGFloat?

    @State private var thumbnail: CGImage?

    init(item: NodeItem, store: ThumbnailStore, node: MEGANode? = nil, size: CGFloat, cornerRadius: CGFloat? = nil) {
        self.item = item
        self.store = store
        self.node = node
        self.size = size
        self.cornerRadius = cornerRadius
        _thumbnail = State(initialValue: item.hasThumbnail ? store.cached(item.id) : nil)
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.16, style: .continuous))
            } else {
                Image(nsImage: FileIcons.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.id) {
            thumbnail = item.hasThumbnail ? store.cached(item.id) : nil
            guard item.hasThumbnail, thumbnail == nil else { return }
            let image = await store.thumbnail(item.id, node: node)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }
}

/// Small status marks after a name.
struct NodeBadges: View {
    let item: NodeItem

    var body: some View {
        HStack(spacing: 4) {
            if item.isExported {
                Image(systemName: "link").foregroundStyle(.secondary)
            }
            if item.isShared {
                Image(systemName: "person.2.fill").foregroundStyle(.secondary)
            }
            if item.isFavourite {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
            if item.isTakenDown {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            if let label = NodeLabel(rawValue: item.label), label != .none {
                Circle().fill(Color(nsColor: label.color)).frame(width: 8, height: 8)
            }
        }
        .imageScale(.small)
        .font(.caption)
    }
}

/// A size in a small glass capsule.
struct SizeTag: View {
    let bytes: Int64

    var body: some View {
        Text(Format.bytes(bytes))
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
    }
}

struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var tint: Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .megaRed
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(height, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}

/// A short message at the top of the window.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.text, systemImage: toast.symbol)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
    }
}

struct TransferPill: View {
    @Environment(AppModel.self) private var app
    var action: () -> Void

    var body: some View {
        let transfers = app.transfers
        if transfers.showsActivity {
            Button(action: action) {
                HStack(spacing: 10) {
                    ProgressView(value: transfers.overallProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    SpeedSlot(symbol: "arrow.down", bytesPerSecond: transfers.downloadSpeed)
                    SpeedSlot(symbol: "arrow.up", bytesPerSecond: transfers.uploadSpeed)
                    Text("\(transfers.activeCount)")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .help("Show transfers")
        }
    }
}

/// One speed with a fixed width, so the pill does not change size as the value changes.
struct SpeedSlot: View {
    let symbol: String
    let bytesPerSecond: Int64

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(Format.speed(bytesPerSecond))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
        }
        .opacity(bytesPerSecond > 0 ? 1 : 0.4)
    }
}

extension View {
    /// Rounded glass panel.
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
