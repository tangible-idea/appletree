import SwiftUI
import AppleTreeCore

private struct MapItem: Identifiable {
    let node: FileNode
    let index: Int
    var grouped = false
    var id: String { node.id }
}

struct MapPanel: View {
    @EnvironmentObject private var store: AppStore

    private var items: [MapItem] {
        let allChildren = store.current.children
        guard !allChildren.isEmpty else { return [] }

        var result: [MapItem] = []
        var top18Size: Int64 = 0
        var topCount = 0

        for (idx, child) in allChildren.prefix(18).enumerated() {
            guard child.size > 0 else { break }
            result.append(MapItem(node: child, index: idx))
            top18Size += child.size
            topCount += 1
        }

        if allChildren.count > topCount {
            let restCount = allChildren.count - topCount
            let restSize = max(0, store.current.size - top18Size)
            if restSize > 0 {
                let group = FileNode(url: store.current.url.appendingPathComponent(".appletree-visual-group"),
                                     name: L10n.count(.otherItems, restCount), isDirectory: true,
                                     size: restSize, fileCount: restCount)
                result.append(MapItem(node: group, index: topCount, grouped: true))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text(L10n.text("map.title")).font(.system(size: 15, weight: .semibold))
                Text(L10n.text("map.subtitle")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
                Label(L10n.text("map.hint"), systemImage: "cursorarrow.click.2")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { proxy in
                let nodes = items
                let tiles = Treemap.layout(weights: nodes.map { $0.node.size }, in: CGRect(origin: .zero, size: proxy.size))
                if tiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                        Text(L10n.text("map.empty")).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 9))
                } else {
                    ZStack(alignment: .topLeading) {
                        ForEach(tiles, id: \.index) { tile in
                            let item = nodes[tile.index]
                            MapTile(node: item.node, color: Theme.color(item.index),
                                    total: store.current.size, selected: store.selected?.id == item.node.id,
                                    grouped: item.grouped, width: tile.rect.width - 5, height: tile.rect.height - 5)
                                .frame(width: max(0, tile.rect.width - 5), height: max(0, tile.rect.height - 5))
                                .position(x: tile.rect.midX, y: tile.rect.midY)
                                .onTapGesture(count: 2) {
                                    if item.grouped { store.showMap = false }
                                    else if item.node.isDirectory { store.enter(item.node) }
                                    else { store.selected = item.node }
                                }
                                .onTapGesture { if !item.grouped { store.selected = item.node } }
                                .contextMenu { if !item.grouped { NodeMenu(node: item.node) } }
                                .help("\(item.node.name) · \(SizeText.format(item.node.size)) · \(percentage(item.node.size, store.current.size))%")
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(L10n.format("map.accessibility", item.node.name, SizeText.format(item.node.size), percentage(item.node.size, store.current.size)))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { if item.grouped { store.showMap = false } else { store.open(item.node) } }
                        }
                    }
                }
            }.frame(height: 244)
            HStack(spacing: 16) {
                ForEach(items.prefix(7)) { item in
                    HStack(spacing: 5) {
                        Circle().fill(Theme.color(item.index)).frame(width: 6, height: 6)
                        Text(item.node.name).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

private struct MapTile: View {
    let node: FileNode
    let color: Color
    let total: Int64
    let selected: Bool
    let grouped: Bool
    let width: CGFloat
    let height: CGFloat
    @State private var hovering = false

    private var big: Bool { width > 220 && height > 150 }
    private var showLabel: Bool { width > 64 && height > 45 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(color.gradient)
            if showLabel {
                VStack(alignment: .leading, spacing: big ? 10 : 6) {
                    HStack(alignment: .top) {
                        Image(systemName: grouped ? "ellipsis" : node.kind.symbol)
                            .font(.system(size: big ? 20 : 13, weight: .medium)).opacity(0.85)
                        Spacer(minLength: 3)
                        if width > 145 {
                            Text("\(percentage(node.size, total))%")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).opacity(0.8)
                        }
                    }
                    if height > 115 { Spacer(minLength: 0) }
                    Text(node.name).font(.system(size: big ? 20 : 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if height > 72 {
                        Text(SizeText.format(node.size))
                            .font(.system(size: big ? 28 : 16, weight: .medium, design: .rounded)).tracking(-0.5)
                    }
                    if big {
                        Text(L10n.count(.files, node.fileCount)).font(.system(size: 10)).opacity(0.7)
                    }
                }
                .padding(big ? 22 : 13).foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(selected ? 0.95 : (hovering ? 0.65 : 0)), lineWidth: selected ? 3 : 2))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.ink.opacity(selected ? 0.25 : 0), lineWidth: 1))
        .brightness(hovering ? 0.025 : 0)
        .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

struct NodeMenu: View {
    @EnvironmentObject private var store: AppStore
    let node: FileNode
    var body: some View {
        if node.isDirectory { Button(L10n.text("action.browse")) { store.enter(node) } }
        else { Button(L10n.text("action.openFile")) { store.open(node) }.disabled(store.isDemo) }
        Button(L10n.text("action.reveal")) { store.reveal(node) }.disabled(store.isDemo)
        Button(L10n.text("action.copyPath")) { store.copyPath(node) }.disabled(store.isDemo)
        Divider()
        Button(L10n.text("action.trashMenu"), role: .destructive) { store.trashCandidate = node }
            .disabled(store.isDemo || store.isScanning)
    }
}
