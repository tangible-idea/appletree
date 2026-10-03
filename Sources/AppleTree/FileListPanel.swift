import SwiftUI
import AppleTreeCore

struct FileListPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let rows = store.outlineRows
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(BrowserMode.allCases, id: \.self) { mode in
                        Button { withAnimation(.snappy(duration: 0.25)) { store.mode = mode } } label: {
                            Text(mode.title).font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .foregroundStyle(store.mode == mode ? Theme.ink : Theme.secondary)
                                .background(store.mode == mode ? .white : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .shadow(color: .black.opacity(store.mode == mode ? 0.035 : 0), radius: 2, y: 1)
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 6) {
                    Text(L10n.count(.items, store.matchingCount))
                    if store.isShowingResults && store.results.totalCount > 0 {
                        Text("· " + SizeText.format(store.results.totalSize)).fontWeight(.semibold)
                    }
                    if store.isSearching { ProgressView().controlSize(.mini) }
                }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
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
                Button { withAnimation(.spring(duration: 0.4, bounce: 0.1)) { store.showMap.toggle() } } label: {
                    Image(systemName: store.showMap ? "rectangle.grid.1x2" : "square.grid.2x2")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }.buttonStyle(.plain).help(store.showMap ? L10n.text("list.only") : L10n.text("list.showMap"))
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            FilterBar().padding(.horizontal, 18).padding(.bottom, 12)

            HStack(spacing: 14) {
                Text(L10n.text("list.name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("list.size")).frame(width: 87, alignment: .trailing)
                Text(L10n.text("list.share")).frame(width: 142, alignment: .trailing)
                Text(L10n.text("list.kind")).frame(width: 68, alignment: .leading)
                Color.clear.frame(width: 51, height: 1)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 21).padding(.vertical, 10).background(Theme.background)

            if rows.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: store.isShowingResults ? "magnifyingglass" : "tray").font(.system(size: 24))
                    Text(store.isShowingResults ? L10n.text("list.noResults") : L10n.text("list.empty")).font(.system(size: 12))
                }.foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        VStack(spacing: 0) {
                            if row.hiddenCount > 0 { MoreRow(row: row) } else { FileRow(node: row.node, depth: row.depth) }
                            Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1).padding(.leading, 20)
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.22), value: store.current.id)
            }

            if store.matchingCount > AppStore.rowLimit {
                Text(L10n.format("list.limit", AppStore.rowLimit.formatted()))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(13)
            }
            if let selected = store.selected { SelectionBar(node: selected) }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

/// Kind chips (multi-select) plus one smart preset, all answered from the scan index.
private struct FilterBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SearchPreset.allCases, id: \.self) { preset in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { store.preset = store.preset == preset ? nil : preset }
                    } label: {
                        Label(preset.title, systemImage: store.preset == preset ? "checkmark" : preset.symbol)
                    }
                }
            } label: {
                Label(store.preset?.title ?? L10n.text("filter.smart"), systemImage: store.preset?.symbol ?? "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(store.preset == nil ? Theme.ink : Theme.accent)
            .background(store.preset == nil ? Theme.background : Theme.accent.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(store.preset == nil ? Theme.line : Theme.accent.opacity(0.35), lineWidth: 1))

            Rectangle().fill(Theme.line).frame(width: 1, height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FileKind.filterable, id: \.self) { kind in
                        let on = store.kindFilter.contains(kind)
                        Button { withAnimation(.snappy(duration: 0.2)) { store.toggleKind(kind) } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: kind.symbol).font(.system(size: 9))
                                Text(kind.title).font(.system(size: 11, weight: on ? .semibold : .regular))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(on ? .white : Theme.secondary)
                            .background(on ? Theme.kindColor(kind) : Theme.background, in: Capsule())
                            .overlay(Capsule().stroke(on ? .clear : Theme.line, lineWidth: 1))
                            .contentShape(Capsule())
                            .scaleEffect(on ? 1.04 : 1)
                        }.buttonStyle(.plain)
                    }
                }
            }

            if store.hasFilters {
                Button(L10n.text("filter.clear")) { withAnimation(.snappy(duration: 0.2)) { store.clearFilters() } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.snappy(duration: 0.2), value: store.hasFilters)
    }
}

private struct MoreRow: View {
    @EnvironmentObject private var store: AppStore
    let row: OutlineRow

    var body: some View {
        Button { store.enter(row.node) } label: {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis.circle").font(.system(size: 11))
                Text(L10n.format("list.more", row.hiddenCount.formatted(), row.node.name)).font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 21 + CGFloat(row.depth) * 20 + 20).padding(.trailing, 21).padding(.vertical, 8)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct FileRow: View {
    @EnvironmentObject private var store: AppStore
    let node: FileNode
    var depth = 0
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if !store.isShowingResults {
                    Button { withAnimation(.easeOut(duration: 0.15)) { store.toggleExpanded(node) } } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(store.expanded.contains(node.id) ? 90 : 0))
                            .frame(width: 14, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    .opacity(node.isDirectory && !node.children.isEmpty ? 1 : 0)
                    .disabled(!node.isDirectory || node.children.isEmpty)
                    .accessibilityLabel(L10n.text(store.expanded.contains(node.id) ? "action.collapse" : "action.expand"))
                }
                FileIcon(node: node, size: depth > 0 ? 26 : 32)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if node.kind == .certificate {
                            Label(L10n.text("badge.sensitive"), systemImage: "lock.fill")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.kindColor(.certificate))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.kindColor(.certificate).opacity(0.1), in: Capsule())
                        }
                    }
                    if store.isShowingResults {
                        Text(node.url.deletingLastPathComponent().path).font(.system(size: 9))
                            .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: store.selected?.id)
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
