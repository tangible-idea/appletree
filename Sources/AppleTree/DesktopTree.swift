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
        let panel = TreePanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 440),
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
                    HedgehogDrawing(mood: mood, fallenApples: fallenApples)
                    flyingIcon
                }
                .frame(width: HedgehogDrawing.size.width, height: HedgehogDrawing.size.height)
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
            panel.frame(width: 264)
            Spacer(minLength: 0)
        }
        .frame(width: 280, height: 440, alignment: .top)
        .onHover { isHovering = $0 }
        .id(appLanguage)
    }

    private var mood: HedgehogDrawing.Mood {
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
            Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                .scaleEffect(1 - 0.85 * model.flyProgress)
                .opacity(1 - model.flyProgress * 0.9)
                .offset(x: -10, y: -28 + 30 * model.flyProgress)
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

/// A tiny, round hedgehog facing the viewer with apples on its back.
/// The first `fallenApples` apples drop to the ground beside it.
struct HedgehogDrawing: View {
    enum Mood { case resting, welcoming, thinking }
    let mood: Mood
    let fallenApples: Int

    static let size = CGSize(width: 120, height: 92)
    private static let center = CGPoint(x: 50, y: 50)
    private static let radius = 27.0
    private static let groundY: CGFloat = 84
    private static let apples: [CGPoint] = [CGPoint(x: 37, y: 19), CGPoint(x: 51, y: 13), CGPoint(x: 64, y: 20)]
    private static let fallenX: [CGFloat] = [92, 104, 81]
    private static let coat = Color(hex: 0xB08562)
    private static let coatShade = Color(hex: 0x926B4C)
    private static let spike = Color(hex: 0x7A573E)
    private static let cream = Color(hex: 0xFCEBD5)
    private static let ink = Color(hex: 0x3B2C25)
    private static let blush = Color(hex: 0xF4A3A0)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Ellipse().fill(.black.opacity(0.12)).frame(width: 50, height: 7)
                    .position(x: Self.center.x + (mood == .thinking ? roll(t) : 0), y: Self.groundY)
                if mood == .thinking {
                    ball(t).transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    sitting(t).transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
                ForEach(0..<min(fallenApples, Self.apples.count), id: \.self) { index in
                    AppleView(size: 11)
                        .position(x: Self.fallenX[index], y: Self.groundY - 4)
                        .transition(.asymmetric(insertion: .offset(x: Self.apples[index].x - Self.fallenX[index],
                                                                   y: Self.apples[index].y - Self.groundY + 4)
                                                    .combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .animation(.spring(response: 0.4, dampingFraction: 0.65), value: mood)
            .animation(.interpolatingSpring(stiffness: 150, damping: 10), value: fallenApples)
        }
    }

    // MARK: Sitting

    private func sitting(_ t: TimeInterval) -> some View {
        let breathe = 1 + 0.03 * sin(t * 2)
        let hop = mood == .welcoming ? -5 * abs(sin(t * 8)) : 0
        let wobble = mood == .welcoming ? 0 : 2.5 * sin(t * 1.1)
        return ZStack {
            Canvas { context, _ in
                drawCoat(&context, center: Self.center, puff: mood == .welcoming ? 1.12 : 1)
                drawFace(&context, t: t)
            }
            ForEach(Self.apples.indices, id: \.self) { index in
                if index >= fallenApples {
                    AppleView(size: 12).rotationEffect(.degrees([-14, 0, 14][index])).position(Self.apples[index])
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(x: 1 / breathe.squareRoot(), y: breathe, anchor: UnitPoint(x: 0.42, y: Self.groundY / Self.size.height))
        .rotationEffect(.degrees(wobble), anchor: UnitPoint(x: 0.42, y: Self.groundY / Self.size.height))
        .offset(y: hop)
    }

    /// A soft, scalloped coat: a ring of round bumps instead of sharp spines.
    private func drawCoat(_ context: inout GraphicsContext, center: CGPoint, puff: Double) {
        let r = Self.radius
        // Short, soft spikes poking out around the back so it reads as a hedgehog, not a bear.
        let spikes = 18
        for i in 0...spikes {
            let a = .pi * (0.92 + 1.16 * Double(i) / Double(spikes))
            let length = (i % 2 == 0 ? 13.0 : 10.0) * puff
            let tip = CGPoint(x: center.x + (r + length) * cos(a), y: center.y + (r + length) * sin(a))
            var spike = Path()
            spike.move(to: CGPoint(x: center.x + (r - 2) * cos(a - 0.2), y: center.y + (r - 2) * sin(a - 0.2)))
            spike.addQuadCurve(to: tip, control: CGPoint(x: center.x + (r + length * 0.6) * cos(a - 0.08),
                                                          y: center.y + (r + length * 0.6) * sin(a - 0.08)))
            spike.addQuadCurve(to: CGPoint(x: center.x + (r - 2) * cos(a + 0.2), y: center.y + (r - 2) * sin(a + 0.2)),
                               control: CGPoint(x: center.x + (r + length * 0.6) * cos(a + 0.08),
                                                y: center.y + (r + length * 0.6) * sin(a + 0.08)))
            spike.closeSubpath()
            context.fill(spike, with: .color(Self.spike))
        }
        for (ring, color) in [(r * 0.98 * puff, Self.coatShade), (r * 0.9, Self.coat)] {
            let bumps = 13
            var coat = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            for i in 0..<bumps {
                let a = Double(i) / Double(bumps) * 2 * .pi + (color == Self.coat ? .pi / Double(bumps) : 0)
                let p = CGPoint(x: center.x + ring * cos(a), y: center.y + ring * sin(a))
                let bump = r * 0.36
                coat.addEllipse(in: CGRect(x: p.x - bump, y: p.y - bump, width: bump * 2, height: bump * 2))
            }
            context.fill(coat, with: .color(color))
        }
        // A few quill strokes on the coat.
        for (dx, dy) in [(-14.0, -16.0), (0, -20), (14, -16), (-21, -4), (21, -4)] {
            var quill = Path()
            quill.move(to: CGPoint(x: center.x + dx - 2.5, y: center.y + dy + 2))
            quill.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy - 2))
            quill.addLine(to: CGPoint(x: center.x + dx + 2.5, y: center.y + dy + 2))
            context.stroke(quill, with: .color(Self.coatShade), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        // Little feet peeking out underneath.
        for x in [-9.0, 9] {
            context.fill(Path(ellipseIn: CGRect(x: center.x + x - 5, y: Self.groundY - 7, width: 10, height: 6)),
                         with: .color(Color(hex: 0xE9C9A6)))
        }
    }

    private func drawFace(_ context: inout GraphicsContext, t: TimeInterval) {
        let c = Self.center
        // Ears
        for x in [-17.0, 17] {
            context.fill(Path(ellipseIn: CGRect(x: c.x + x - 3.5, y: c.y - 11, width: 7, height: 7)), with: .color(Self.cream))
            context.fill(Path(ellipseIn: CGRect(x: c.x + x - 1.75, y: c.y - 9.25, width: 3.5, height: 3.5)), with: .color(Self.blush))
        }
        // Face: wide and low, so the eyes sit low like a baby's.
        context.fill(Path(ellipseIn: CGRect(x: c.x - 20, y: c.y - 11, width: 40, height: 33)), with: .color(Self.cream))
        // Cheeks
        let blushAlpha = mood == .welcoming ? 0.85 : 0.6
        for x in [-13.5, 13.5] {
            context.fill(Path(ellipseIn: CGRect(x: c.x + x - 4.5, y: c.y + 7, width: 9, height: 5.5)),
                         with: .color(Self.blush.opacity(blushAlpha)))
        }
        // Eyes: big and glossy, blinking now and then.
        let blinking = mood == .resting && t.truncatingRemainder(dividingBy: 3.8) < 0.13
        for x in [-8.5, 8.5] {
            let eye = CGPoint(x: c.x + x, y: c.y + 2)
            if blinking {
                var lid = Path()
                lid.move(to: CGPoint(x: eye.x - 3.5, y: eye.y))
                lid.addQuadCurve(to: CGPoint(x: eye.x + 3.5, y: eye.y), control: CGPoint(x: eye.x, y: eye.y + 3))
                context.stroke(lid, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            } else {
                let w = mood == .welcoming ? 8.0 : 6.6, h = mood == .welcoming ? 9.0 : 7.6
                context.fill(Path(ellipseIn: CGRect(x: eye.x - w / 2, y: eye.y - h / 2, width: w, height: h)), with: .color(Self.ink))
                context.fill(Path(ellipseIn: CGRect(x: eye.x - w * 0.05, y: eye.y - h * 0.4, width: w * 0.42, height: w * 0.42)),
                             with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(x: eye.x - w * 0.3, y: eye.y + h * 0.12, width: w * 0.2, height: w * 0.2)),
                             with: .color(.white.opacity(0.8)))
            }
        }
        // Button nose and a tiny smile
        let sniff = 0.5 * sin(t * 10) * max(0, sin(t * 0.7))
        context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y + 6 + sniff, width: 6, height: 4.4)), with: .color(Self.ink))
        var mouth = Path()
        mouth.move(to: CGPoint(x: c.x - 3, y: c.y + 12))
        mouth.addQuadCurve(to: CGPoint(x: c.x, y: c.y + 12), control: CGPoint(x: c.x - 1.5, y: c.y + 14))
        mouth.addQuadCurve(to: CGPoint(x: c.x + 3, y: c.y + 12), control: CGPoint(x: c.x + 1.5, y: c.y + 14))
        context.stroke(mouth, with: .color(Self.ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    // MARK: Curled up and rolling

    private func roll(_ t: TimeInterval) -> CGFloat { 13 * sin(t * 3) }

    private func ball(_ t: TimeInterval) -> some View {
        let x = roll(t)
        let ballRadius = 22.0
        let center = CGPoint(x: Self.center.x, y: Self.groundY - ballRadius - 3)
        return Canvas { context, _ in
            var coat = context
            let r = ballRadius
            for (ring, color, offset) in [(r * 0.98, Self.coatShade, 0.0), (r * 0.86, Self.coat, Double.pi / 11)] {
                var path = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                for i in 0..<11 {
                    let a = Double(i) / 11 * 2 * .pi + offset
                    let p = CGPoint(x: center.x + ring * cos(a), y: center.y + ring * sin(a))
                    path.addEllipse(in: CGRect(x: p.x - r * 0.38, y: p.y - r * 0.38, width: r * 0.76, height: r * 0.76))
                }
                coat.fill(path, with: .color(color))
            }
            // The tucked-in face peeks out, eyes squeezed shut.
            coat.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y + 4, width: 20, height: 14)), with: .color(Self.cream))
            coat.fill(Path(ellipseIn: CGRect(x: center.x + 11, y: center.y + 9, width: 5, height: 4)), with: .color(Self.ink))
            var eye = Path()
            eye.move(to: CGPoint(x: center.x + 1, y: center.y + 9))
            eye.addLine(to: CGPoint(x: center.x + 4, y: center.y + 10.5))
            eye.addLine(to: CGPoint(x: center.x + 1, y: center.y + 12))
            coat.stroke(eye, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .rotationEffect(.radians(Double(x) / ballRadius), anchor: UnitPoint(x: center.x / Self.size.width, y: center.y / Self.size.height))
        .offset(x: x)
    }
}
