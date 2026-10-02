import SwiftUI
import AppleTreeCore

struct Sidebar: View {
    @EnvironmentObject private var store: AppStore
    private let shortcuts: [(String, String, String)] = [
        ("house", L10n.text("sidebar.home"), ""), ("arrow.down.circle", L10n.text("sidebar.downloads"), "Downloads"),
        ("desktopcomputer", L10n.text("sidebar.desktop"), "Desktop"), ("doc.text", L10n.text("sidebar.documents"), "Documents"),
        ("photo.on.rectangle", L10n.text("sidebar.pictures"), "Pictures"), ("play.rectangle", L10n.text("sidebar.movies"), "Movies")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tree.fill").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent).frame(width: 35, height: 38)
                Text("appletree").font(.system(size: 23, weight: .bold, design: .rounded)).tracking(-0.8)
            }
            .padding(.top, 48).padding(.bottom, 38).padding(.horizontal, 24)

            SmallLabel(text: L10n.text("sidebar.workspace")).padding(.horizontal, 27).padding(.bottom, 12)
            Button {
                store.navigate(to: store.root)
                store.mode = .folders
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "square.grid.2x2.fill").frame(width: 18)
                    Text(L10n.text("sidebar.overview")).fontWeight(.semibold)
                    Spacer()
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 13).padding(.vertical, 12)
                .background(Theme.accent.opacity(0.095), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 14)

            SmallLabel(text: L10n.text("sidebar.shortcuts")).padding(.horizontal, 27).padding(.top, 33).padding(.bottom, 12)
            ForEach(shortcuts, id: \.2) { symbol, title, path in
                Button {
                    store.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 15)).frame(width: 19)
                        Text(title).font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(Theme.secondary).padding(.horizontal, 13).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 14).disabled(store.isScanning)
                .help(L10n.format("sidebar.scan", title))
            }

            Button { store.chooseFolder() } label: {
                Label(L10n.text("sidebar.choose"), systemImage: "plus").font(.system(size: 12))
                    .foregroundStyle(Theme.secondary).padding(.horizontal, 27).padding(.top, 17)
            }.buttonStyle(.plain)

            Spacer(minLength: 35)
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive").font(.system(size: 17)).foregroundStyle(Theme.secondary)
                    Text(store.isDemo ? L10n.text("sidebar.mac") : L10n.text("sidebar.volume")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Circle().fill(Theme.green).frame(width: 6, height: 6)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.green).frame(width: proxy.size.width * max(0, min(1, store.diskUsedFraction)))
                    }
                }.frame(height: 5)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(SizeText.format(store.diskFree)).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(L10n.text("sidebar.available")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Text(L10n.format("sidebar.total", SizeText.format(store.diskTotal)))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            .padding(16).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 18).padding(.bottom, 21)
            HStack(spacing: 6) {
                Image(systemName: "leaf").font(.system(size: 11))
                Text(L10n.text("sidebar.tagline")).font(.system(size: 10))
            }.foregroundStyle(Theme.secondary).padding(.horizontal, 28).padding(.bottom, 23)
        }
        .frame(width: 218).background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}
