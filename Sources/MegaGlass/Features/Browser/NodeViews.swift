import AppKit
import SwiftUI

/// List view. SwiftUI's Table is backed by NSTableView, so it scrolls large folders smoothly.
struct NodeTable<Menu: View>: View {
    @Bindable var model: BrowserModel
    let menu: (Set<UInt64>) -> Menu
    let open: (Set<UInt64>) -> Void

    @State private var sortOrder: [KeyPathComparator<NodeItem>] = [KeyPathComparator(\NodeItem.name)]

    var body: some View {
        Table(model.items, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    NodeIcon(item: item, store: model.engine.thumbnails, size: 20, cornerRadius: 4)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    NodeBadges(item: item)
                }
            }
            .width(min: 220, ideal: 420)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(Format.date(item.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 170)

            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder && item.size == 0 ? "--" : Format.bytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Length") { item in
                if item.duration > 0 {
                    Text(Format.playtime(Double(item.duration)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 56, ideal: 70)

            TableColumn("Kind", value: \.kindTitle) { item in
                Text(item.kindTitle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: UInt64.self, menu: menu, primaryAction: open)
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            let key: SortKey = switch first.keyPath {
            case \NodeItem.size: .size
            case \NodeItem.modified: .modified
            case \NodeItem.kindTitle: .kind
            default: .name
            }
            model.setSort(key, ascending: first.order == .forward)
        }
        .onAppear { syncSortOrder() }
        .onChange(of: model.sortKey) { syncSortOrder() }
        .onChange(of: model.ascending) { syncSortOrder() }
    }

    /// Shows the model's sort in the column headers when it changes from the toolbar.
    private func syncSortOrder() {
        let order: SortOrder = model.ascending ? .forward : .reverse
        let comparator: KeyPathComparator<NodeItem> = switch model.sortKey {
        case .name: KeyPathComparator(\NodeItem.name, order: order)
        case .size: KeyPathComparator(\NodeItem.size, order: order)
        case .modified: KeyPathComparator(\NodeItem.modified, order: order)
        case .kind: KeyPathComparator(\NodeItem.kindTitle, order: order)
        }
        if sortOrder.first != comparator { sortOrder = [comparator] }
    }
}

/// Grid view with thumbnails.
struct NodeGrid<Menu: View>: View {
    @Bindable var model: BrowserModel
    let size: CGFloat
    let menu: (Set<UInt64>) -> Menu
    let open: (Set<UInt64>) -> Void

    @State private var anchor: UInt64?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size + 40), spacing: 12)], spacing: 14) {
                ForEach(model.items) { item in
                    GridCell(item: item, store: model.engine.thumbnails, size: size,
                             selected: model.selection.contains(item.id))
                        .onTapGesture { click(item) }
                        .contextMenu {
                            menu(model.selection.contains(item.id) ? model.selection : [item.id])
                        }
                }
            }
            .padding(16)
        }
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.selection.removeAll() }
                .contextMenu { menu([]) }
        }
    }

    private func click(_ item: NodeItem) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if event?.clickCount == 2 {
            open([item.id])
            return
        }
        if flags.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
            anchor = item.id
        } else if flags.contains(.shift), let anchor,
                  let from = model.items.firstIndex(where: { $0.id == anchor }),
                  let to = model.items.firstIndex(where: { $0.id == item.id }) {
            let range = min(from, to)...max(from, to)
            model.selection = Set(model.items[range].map(\.id))
        } else {
            model.selection = [item.id]
            anchor = item.id
        }
    }
}

/// Length of a video on its thumbnail.
struct DurationBadge: View {
    let seconds: Int

    var body: some View {
        Text(Format.playtime(Double(seconds)))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .environment(\.colorScheme, .dark)
    }
}

private struct GridCell: View {
    let item: NodeItem
    let store: ThumbnailStore
    let size: CGFloat
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            NodeIcon(item: item, store: store, size: size - 28, cornerRadius: 12)
                .shadow(color: .black.opacity(item.hasThumbnail ? 0.18 : 0), radius: 4, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    NodeBadges(item: item)
                        .padding(4)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.duration > 0 {
                        DurationBadge(seconds: item.duration)
                            .padding(6)
                    }
                }
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .background(selected ? Color.accentColor.opacity(0.85) : .clear, in: .rect(cornerRadius: 5))
                .foregroundStyle(selected ? .white : .primary)
        }
        .padding(8)
        .frame(width: size)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect)
    }
}
