import SwiftUI
import AppleTreeCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                toolbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heading
                        if store.isScanning { scanningBanner }
                        else if let notice = store.notice { noticeBanner(notice) }
                        metrics
                        if store.showMap { MapPanel() }
                        FileListPanel()
                        footer
                    }.padding(.horizontal, 32).padding(.top, 27).padding(.bottom, 22)
                }
            }
        }
        .foregroundStyle(Theme.ink).background(Theme.background)
        .alert(L10n.text("error.title"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L10n.text("action.ok"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog(L10n.format("trash.title", store.trashCandidate?.name ?? ""),
                            isPresented: Binding(get: { store.trashCandidate != nil }, set: { if !$0 { store.trashCandidate = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.text("action.trash"), role: .destructive) { store.moveToTrash() }
            Button(L10n.text("action.cancel"), role: .cancel) { store.trashCandidate = nil }
        } message: { Text(L10n.text("trash.message")) }
    }

    private var toolbar: some View {
        HStack(spacing: 13) {
            IconButton(symbol: "chevron.left", help: L10n.text("action.back"), disabled: store.navigation.isEmpty) { store.goBack() }
            Rectangle().fill(Theme.line).frame(width: 1, height: 16)
            Image(systemName: "internaldrive").foregroundStyle(Theme.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(Array(store.breadcrumbs.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.secondary) }
                        Button(node.name) { store.navigate(to: node) }.buttonStyle(.plain)
                            .font(.system(size: 11, weight: node.id == store.current.id ? .semibold : .regular))
                            .foregroundStyle(node.id == store.current.id ? Theme.ink : Theme.secondary)
                    }
                }
            }
            Spacer(minLength: 10)
            if store.isDemo {
                Text(L10n.text("preview.badge")).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.08), in: Capsule())
            }
            IconButton(symbol: "arrow.clockwise", help: L10n.text("action.refreshHelp"), disabled: store.isScanning) { store.refresh() }
            Button { store.chooseFolder() } label: {
                Label(L10n.text("action.scan"), systemImage: "folder.badge.plus")
            }.buttonStyle(AccentButtonStyle()).keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 25).frame(height: 66)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                SmallLabel(text: "A LITTLE SPACE. A LITTLE CLARITY.")
                Text(L10n.text("heading.title")).font(.system(size: 29, weight: .bold)).tracking(-1)
                Text(store.isDemo ? L10n.text("heading.subtitle") : L10n.format("heading.folder", store.current.name))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if store.isDemo {
                VStack(alignment: .trailing, spacing: 6) {
                    Label(L10n.text("preview.caption"), systemImage: "sparkle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    Button(L10n.text("preview.start")) { store.chooseFolder() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            } else {
                Label(L10n.text("scan.complete"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.green)
                    .opacity(store.isScanning ? 0 : 1)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 13) {
            MetricCard(title: L10n.text("metric.size"), value: SizeText.format(store.current.size),
                       detail: store.isDemo ? L10n.text("preview.data") : L10n.text("metric.sum"), symbol: "chart.pie", accent: true)
            MetricCard(title: L10n.text("metric.files"), value: store.current.fileCount.formatted(),
                       detail: L10n.count(.subfolders, store.current.children.filter { $0.isDirectory }.count), symbol: "doc.on.doc")
            MetricCard(title: L10n.text("metric.largest"), value: store.largestFolder?.name ?? "—",
                       detail: store.largestFolder.map { L10n.format("metric.share", SizeText.format($0.size), percentage($0.size, store.current.size)) } ?? L10n.text("metric.noFolders"),
                       symbol: "folder", compact: true)
        }
    }

    private var scanningBanner: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("scan.running")).font(.system(size: 12, weight: .semibold))
                Text(store.progress.map { L10n.format("scan.progress", L10n.count(.files, $0.files), SizeText.format($0.bytes), $0.path) } ?? L10n.text("scan.reading"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L10n.text("action.cancel")) { store.cancelScan() }.buttonStyle(QuietButtonStyle()).font(.system(size: 11))
        }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 10))
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Spacer()
            IconButton(symbol: "xmark", help: L10n.text("action.dismiss")) { store.notice = nil }
        }.padding(.horizontal, 12).padding(.vertical, 5).background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text(L10n.text("footer.privacy"))
            Spacer()
            Text(store.report.map { L10n.format("footer.elapsed", String(format: "%.1f", locale: Locale.current, $0.elapsed)) } ?? "")
                + Text(L10n.text("footer.basis"))
        }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
    }
}

func percentage(_ size: Int64, _ total: Int64) -> String {
    guard total > 0 else { return "0" }
    return String(format: "%.1f", locale: Locale.current, Double(size) / Double(total) * 100)
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var accent = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(accent ? Theme.accent : Theme.secondary)
            }
            Text(value).font(.system(size: compact ? 24 : 29, weight: .semibold, design: .rounded))
                .tracking(-0.8).lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(accent ? Theme.accent : Theme.ink)
            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .frame(height: 88, alignment: .top)
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent ? Color(hex: 0xFBF1EA) : .white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent ? Color(hex: 0xF0DED0) : Theme.line, lineWidth: 1))
    }
}
