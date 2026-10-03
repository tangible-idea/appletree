import SwiftUI
import AppleTreeCore

struct FileListPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(BrowserMode.allCases, id: \.self) { mode in
                        Button { store.mode = mode } label: {
                            Text(mode.title).font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .foregroundStyle(store.mode == mode ? Theme.ink : Theme.secondary)
                                .background(store.mode == mode ? .white : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .shadow(color: .black.opacity(store.mode == mode ? 0.035 : 0), radius: 2, y: 1)
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.count(.items, store.matchingCount)).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    TextField(L10n.text("list.search"), text: $store.query)
                        .textFieldStyle(.plain).font(.system(size: 11)).frame(width: 164)
                        .accessibilityLabel(L10n.text("list.search"))
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(L10n.text("list.clearSearch"))
                    }
                }.padding(8).background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                Button { store.showMap.toggle() } label: {
                    Image(systemName: store.showMap ? "rectangle.grid.1x2" : "square.grid.2x2")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }.buttonStyle(.plain).help(store.showMap ? L10n.text("list.only") : L10n.text("list.showMap"))
            }.padding(.horizontal, 18).padding(.vertical, 14)

            HStack(spacing: 14) {
                Text(L10n.text("list.name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("list.size")).frame(width: 87, alignment: .trailing)
                Text(L10n.text("list.share")).frame(width: 142, alignment: .trailing)
                Text(L10n.text("list.kind")).frame(width: 68, alignment: .leading)
                Color.clear.frame(width: 51, height: 1)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 21).padding(.vertical, 10).background(Theme.background)

            if store.visibleItems.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: store.query.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 24))
                    Text(store.query.isEmpty ? L10n.text("list.empty") : L10n.text("list.noResults")).font(.system(size: 12))
                }.foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleItems) { node in
                        FileRow(node: node)
                        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1).padding(.leading, 20)
                    }
                }
            }

            if store.matchingCount > 200 {
                Text(L10n.text("list.limit"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(13)
            }
            if let selected = store.selected { SelectionBar(node: selected) }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

private struct FileRow: View {
    @EnvironmentObject private var store: AppStore
    let node: FileNode
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                FileIcon(node: node)
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if store.mode == .largest || !store.query.isEmpty {
                        Text(node.url.deletingLastPathComponent().path).font(.system(size: 9))
                            .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if node.isDirectory { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.secondary) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(SizeText.format(node.size)).font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit().frame(width: 87, alignment: .trailing)
            HStack(spacing: 9) {
                let fraction = store.current.size > 0 ? min(1.0, max(0.0, Double(node.size) / Double(store.current.size))) : 0.0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sidebar).frame(width: 77, height: 4)
                    if fraction > 0 {
                        Capsule().fill(Theme.kindColor(node.kind).opacity(0.7))
                            .frame(width: max(2, 77 * fraction), height: 4)
                    }
                }
                .frame(width: 77, height: 4)
                Text("\(percentage(node.size, store.current.size))%")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.secondary)
                    .frame(width: 45, alignment: .trailing)
            }.frame(width: 142, alignment: .trailing)
            Text(node.kind.title).font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 68, alignment: .leading)
            HStack(spacing: 0) {
                IconButton(symbol: "arrow.up.forward.square", help: L10n.text("action.reveal"), disabled: store.isDemo) { store.reveal(node) }
                Menu { NodeMenu(node: node) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 28)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("action.fileActions"))
            }.frame(width: 51)
        }
        .padding(.horizontal, 21).padding(.vertical, 9)
        .background(store.selected?.id == node.id ? Theme.accent.opacity(0.07) : (hovering ? Theme.background : .white))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(node) }
        .onTapGesture { store.selected = node }
        .onHover { hovering = $0 }
        .contextMenu { NodeMenu(node: node) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L10n.text("action.open")) { store.open(node) }
    }
}

private struct SelectionBar: View {
    @EnvironmentObject private var store: AppStore
    let node: FileNode
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbol).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.url.path).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(SizeText.format(node.size) + (node.modified.map { L10n.format("selection.modified", $0.formatted(date: .abbreviated, time: .omitted)) } ?? ""))
                    .font(.system(size: 9)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button(node.isDirectory ? L10n.text("action.browse") : L10n.text("action.openFile")) { store.open(node) }
                .buttonStyle(QuietButtonStyle()).font(.system(size: 10)).disabled(!node.isDirectory && store.isDemo)
            IconButton(symbol: "trash", help: L10n.text("action.trash"), disabled: store.isDemo || store.isScanning) { store.trashCandidate = node }
            IconButton(symbol: "xmark", help: L10n.text("action.clearSelection")) { store.selected = nil }
        }.padding(13).background(Theme.background)
    }
}
