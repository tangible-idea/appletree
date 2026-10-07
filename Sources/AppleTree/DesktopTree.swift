import SwiftUI
import AppKit
import AppleTreeCore

enum DesktopTreePreference {
    static let key = "showDesktopTree"
    static let defaultValue = true
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
}

/// What the tree is doing with the most recently dropped file.
@MainActor
final class DesktopTreeModel: ObservableObject {
    enum Phase {
        case idle
        case thinking(DroppedFile)
        case suggestions(DroppedFile, [FolderSuggestion], noMatch: Double, skipped: Int)
        case moved(original: URL, current: URL, folder: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The dropped file's icon while it flies up into the canopy.
    @Published private(set) var flyingIcon: NSImage?
    @Published private(set) var flyProgress = 0.0
    var onPhaseChange: ((Phase) -> Void)?
    private var resetTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?

    var isBusy: Bool { if case .thinking = phase { true } else { false } }

    func drop(_ urls: [URL]) {
        guard !isBusy, let url = urls.first?.standardizedFileURL else { return }
        resetTask?.cancel()
        let file = DroppedFile(url: url)
        flyingIcon = NSWorkspace.shared.icon(forFile: url.path)
        flyProgress = 0
        withAnimation(.easeIn(duration: 0.7)) { flyProgress = 1 }
        set(.thinking(file))
        let skipped = urls.count - 1
        requestTask = Task { [weak self] in
            let started = ContinuousClock.now
            let outcome = await Self.suggest(for: file)
            // Let the canopy rustle for a beat even when the answer comes back quickly.
            try? await Task.sleep(until: started + .milliseconds(1400))
            guard let self, !Task.isCancelled else { return }
            flyingIcon = nil
            switch outcome {
            case .success(let result) where result.ranked.isEmpty:
                set(.failed(L10n.text("tree.noGoodFit")))
            case .success(let result):
                set(.suggestions(file, result.ranked, noMatch: result.noMatch, skipped: skipped))
            case .failure(let message):
                set(.failed(message))
            }
        }
    }

    func move(_ file: DroppedFile, to suggestion: FolderSuggestion) {
        do {
            let current = try FileMover.move(file.url, into: suggestion.folder.url)
            set(.moved(original: file.url, current: current, folder: suggestion.folder.name))
            resetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        } catch {
            set(.failed(L10n.format("tree.error.move", error.localizedDescription)))
        }
    }

    func undo(original: URL, current: URL) {
        resetTask?.cancel()
        do {
            try FileMover.undo(movedTo: current, originalLocation: original)
            dismiss()
        } catch {
            set(.failed(L10n.format("tree.error.undo", error.localizedDescription)))
        }
    }

    func dismiss() {
        resetTask?.cancel()
        requestTask?.cancel()
        flyingIcon = nil
        set(.idle)
    }

    private func set(_ phase: Phase) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { self.phase = phase }
        onPhaseChange?(phase)
    }

    private enum Outcome { case success(FolderSuggestions), failure(String) }

    /// Listing folders and calling TypeSafe both happen off the main thread.
    private nonisolated static func suggest(for file: DroppedFile) async -> Outcome {
        guard let client = TypeSafeClient.bundled() else { return .failure(L10n.text("tree.error.noKey")) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = FolderSuggester.candidates(home: home, excluding: file.url)
        guard !candidates.isEmpty else { return .failure(L10n.text("tree.error.noFolders")) }
        do {
            let data = try await client.evaluate(FolderSuggester.requestBody(for: file, candidates: candidates))
            return .success(try FolderSuggester.suggestions(fromResponse: data, candidates: candidates))
        } catch TypeSafeError.unauthorized {
            return .failure(L10n.text("tree.error.unauthorized"))
        } catch {
            return .failure(L10n.text("tree.error.network"))
        }
    }
}

/// Keeps the tree in a borderless panel that sits on the desktop, under ordinary windows.
@MainActor
final class DesktopTreeController {
    static let shared = DesktopTreeController()
    let model = DesktopTreeModel()
    private var panel: NSPanel?
    private let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: DesktopTreePreference.key)
        if visible { show() } else { panel?.orderOut(nil); model.dismiss() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = TreePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = desktopLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DesktopTreeView().environmentObject(model))
        if !panel.setFrameUsingName("AppleTreeDesktopTree"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 340, y: screen.minY + 40))
        }
        panel.setFrameAutosaveName("AppleTreeDesktopTree")
        // Suggestions float above other windows so they aren't hidden; the resting tree stays on the desktop.
        model.onPhaseChange = { [weak panel, desktopLevel] phase in
            if case .idle = phase { panel?.level = desktopLevel } else { panel?.level = .floating }
        }
        return panel
    }
}

private final class TreePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct DesktopTreeView: View {
    @EnvironmentObject private var model: DesktopTreeModel
    @AppStorage(LanguagePreference.key) private var appLanguage = LanguagePreference.system
    @State private var isTargeted = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    AppleTreeDrawing(mood: mood, fallenApples: fallenApples)
                    flyingIcon
                }
                .frame(width: 240, height: 280)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    model.drop(urls)
                    return !urls.isEmpty
                } isTargeted: { isTargeted = $0 }
                .help(L10n.text("tree.hint"))

                if isHovering, case .idle = model.phase {
                    Button { DesktopTreeController.shared.setVisible(false) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
                            .frame(width: 20, height: 20).background(.white.opacity(0.9), in: Circle())
                    }
                    .buttonStyle(.plain).help(L10n.text("tree.hide")).padding(6)
                }
            }
            panel.frame(width: 280)
            Spacer(minLength: 0)
        }
        .frame(width: 300, height: 560, alignment: .top)
        .onHover { isHovering = $0 }
        .id(appLanguage)
    }

    private var mood: AppleTreeDrawing.Mood {
        if isTargeted { return .welcoming }
        if case .thinking = model.phase { return .thinking }
        return .resting
    }

    private var fallenApples: Int {
        switch model.phase {
        case .suggestions(_, let ranked, _, _): ranked.count
        case .moved: 1
        default: 0
        }
    }

    @ViewBuilder private var flyingIcon: some View {
        if let icon = model.flyingIcon {
            Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                .scaleEffect(1 - 0.85 * model.flyProgress)
                .opacity(1 - model.flyProgress * 0.9)
                .offset(y: 110 - 190 * model.flyProgress)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var panel: some View {
        switch model.phase {
        case .idle:
            if isHovering || isTargeted {
                Bubble { Text(L10n.text("tree.hint")).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                    .transition(.opacity)
            }
        case .thinking(let file):
            Bubble {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("tree.thinking")).font(.system(size: 12, weight: .medium))
                        Text(file.url.lastPathComponent).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .transition(.opacity)
        case .suggestions(let file, let ranked, let noMatch, let skipped):
            SuggestionList(file: file, ranked: ranked, noMatch: noMatch, skipped: skipped)
                .transition(.move(edge: .top).combined(with: .opacity))
        case .moved(let original, let current, let folder):
            Bubble {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.format("tree.moved", folder), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                    HStack(spacing: 8) {
                        Button(L10n.text("tree.undo")) { model.undo(original: original, current: current) }
                            .buttonStyle(QuietButtonStyle()).font(.system(size: 11))
                        Button(L10n.text("tree.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([current]) }
                            .buttonStyle(QuietButtonStyle()).font(.system(size: 11))
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        case .failed(let message):
            Bubble {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("action.ok")) { model.dismiss() }.buttonStyle(QuietButtonStyle()).font(.system(size: 11))
                }
            }
            .transition(.opacity)
        }
    }
}

private struct SuggestionList: View {
    @EnvironmentObject private var model: DesktopTreeModel
    let file: DroppedFile
    let ranked: [FolderSuggestion]
    let noMatch: Double
    let skipped: Int
    @State private var shown = 0

    var body: some View {
        Bubble {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.format("tree.question", file.url.lastPathComponent))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                ForEach(Array(ranked.enumerated()), id: \.element.folder.url) { index, suggestion in
                    if index < shown {
                        Button { model.move(file, to: suggestion) } label: { row(suggestion) }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                if noMatch > (ranked.first?.probability ?? 0) {
                    Text(L10n.text("tree.noGoodFit")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                if skipped > 0 {
                    Text(L10n.text("tree.onlyFirst")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Button(L10n.text("tree.notNow")) { model.dismiss() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .task {
            // Each card appears as its apple lands.
            for index in ranked.indices {
                try? await Task.sleep(for: .milliseconds(index == 0 ? 350 : 140))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shown = index + 1 }
            }
        }
    }

    private func row(_ suggestion: FolderSuggestion) -> some View {
        HStack(spacing: 10) {
            AppleView(size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(suggestion.folder.label).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(suggestion.probability.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A white card that reads well on any wallpaper.
private struct Bubble<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .foregroundStyle(Theme.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            // Without a compositing group the shadow is drawn under every row inside the card too.
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

struct AppleView: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xEE7B57), Color(hex: 0xC7432D)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75))
            Circle().fill(.white.opacity(0.45)).frame(width: size * 0.22, height: size * 0.22)
                .offset(x: -size * 0.18, y: -size * 0.18)
            Capsule().fill(Color(hex: 0x6B4A2E)).frame(width: size * 0.09, height: size * 0.28)
                .offset(y: -size * 0.55)
            Ellipse().fill(Color(hex: 0x6E9460)).frame(width: size * 0.32, height: size * 0.16)
                .rotationEffect(.degrees(-25)).offset(x: size * 0.16, y: -size * 0.56)
        }
        .frame(width: size, height: size)
    }
}

/// The tree itself: a trunk, a swaying canopy and its apples. The first `fallenApples` apples drop to the ground.
struct AppleTreeDrawing: View {
    enum Mood { case resting, welcoming, thinking }
    let mood: Mood
    let fallenApples: Int

    // Canopy blobs and apples, in a 240 × 280 space.
    private static let blobs: [(x: CGFloat, y: CGFloat, r: CGFloat, hex: UInt32)] = [
        (120, 78, 62, 0x6E9460), (72, 112, 50, 0x5F8653), (168, 112, 52, 0x5F8653), (96, 70, 46, 0x7FA36A),
        (150, 68, 48, 0x7FA36A), (120, 120, 56, 0x6E9460), (82, 138, 38, 0x7FA36A), (160, 140, 40, 0x7FA36A),
        (120, 52, 38, 0x8DB07A), (100, 98, 34, 0x8DB07A), (145, 100, 32, 0x8DB07A),
    ]
    private static let apples: [CGPoint] = [
        CGPoint(x: 96, y: 118), CGPoint(x: 146, y: 92), CGPoint(x: 122, y: 148),
        CGPoint(x: 74, y: 84), CGPoint(x: 172, y: 128), CGPoint(x: 118, y: 62),
    ]
    private static let groundY: CGFloat = 252

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Ellipse().fill(.black.opacity(0.13)).frame(width: 150, height: 18).position(x: 120, y: 262)
                Trunk().fill(LinearGradient(colors: [Color(hex: 0x9A6A47), Color(hex: 0x7A5034)],
                                            startPoint: .leading, endPoint: .trailing))
                ZStack {
                    ForEach(Self.blobs.indices, id: \.self) { index in
                        let blob = Self.blobs[index]
                        Circle().fill(Color(hex: blob.hex))
                            .frame(width: blob.r * 2, height: blob.r * 2)
                            .position(x: blob.x + rustle(t, index), y: blob.y)
                    }
                    ForEach(Self.apples.indices, id: \.self) { index in
                        if index >= fallenApples {
                            AppleView(size: 18)
                                .scaleEffect(glow(t, index))
                                .position(Self.apples[index])
                        }
                    }
                }
                .brightness(mood == .welcoming ? 0.06 : 0)
                .scaleEffect(mood == .welcoming ? 1.05 : 1, anchor: .bottom)
                .rotationEffect(.degrees(sway(t)), anchor: UnitPoint(x: 0.5, y: 0.85))
                // Fallen apples rest on the ground, outside the swaying canopy.
                ForEach(0..<min(fallenApples, Self.apples.count), id: \.self) { index in
                    AppleView(size: 18)
                        .position(x: [82, 160, 121][index % 3] + CGFloat(index / 3) * 12, y: Self.groundY)
                        .transition(.asymmetric(insertion: .offset(y: Self.apples[index].y - Self.groundY).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .frame(width: 240, height: 280)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: mood)
            .animation(.interpolatingSpring(stiffness: 140, damping: 9), value: fallenApples)
        }
    }

    private func sway(_ t: TimeInterval) -> Double {
        switch mood {
        case .resting: 1.2 * sin(t * 0.9)
        case .welcoming: 2.5 * sin(t * 2.2)
        case .thinking: 1.2 * sin(t * 1.4) + 0.8 * sin(t * 9)
        }
    }

    private func rustle(_ t: TimeInterval, _ index: Int) -> CGFloat {
        mood == .thinking ? CGFloat(1.6 * sin(t * 11 + Double(index))) : 0
    }

    /// While thinking, apples swell one after another.
    private func glow(_ t: TimeInterval, _ index: Int) -> CGFloat {
        guard mood == .thinking else { return 1 }
        return 1 + 0.3 * CGFloat(max(0, sin(t * 4 - Double(index) * 0.9)))
    }
}

private struct Trunk: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 104, y: 262))
        path.addCurve(to: CGPoint(x: 112, y: 150), control1: CGPoint(x: 114, y: 230), control2: CGPoint(x: 110, y: 180))
        path.addCurve(to: CGPoint(x: 86, y: 120), control1: CGPoint(x: 104, y: 136), control2: CGPoint(x: 94, y: 128))
        path.addLine(to: CGPoint(x: 94, y: 114))
        path.addCurve(to: CGPoint(x: 120, y: 140), control1: CGPoint(x: 104, y: 122), control2: CGPoint(x: 114, y: 130))
        path.addCurve(to: CGPoint(x: 150, y: 112), control1: CGPoint(x: 128, y: 128), control2: CGPoint(x: 140, y: 118))
        path.addLine(to: CGPoint(x: 156, y: 118))
        path.addCurve(to: CGPoint(x: 130, y: 152), control1: CGPoint(x: 144, y: 128), control2: CGPoint(x: 134, y: 140))
        path.addCurve(to: CGPoint(x: 138, y: 262), control1: CGPoint(x: 128, y: 190), control2: CGPoint(x: 128, y: 230))
        path.closeSubpath()
        return path
    }
}
