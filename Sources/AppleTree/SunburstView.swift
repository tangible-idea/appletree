import SwiftUI
import AppleTreeCore

/// DaisyDisk-style ring chart: the centre is the current folder and each ring
/// outward is one level deeper. Click a folder slice to step in, the centre to step out.
struct SunburstView: View {
    @EnvironmentObject private var store: AppStore
    /// Hover is tied to the folder it was measured in, so a stale index never outlives navigation.
    @State private var hover: Hover?
    /// 0→1 as the rings sweep in after entering a folder.
    @State private var progress = 0.0
    /// 0→1 as the hovered slice lifts outward.
    @State private var lift = 0.0

    private struct Hover: Equatable {
        let folder: String
        let index: Int
    }

    private func hoveredIndex(_ arcs: [SunburstArc]) -> Int? {
        guard let hover, hover.folder == store.current.id, hover.index < arcs.count else { return nil }
        return hover.index
    }

    private func setHover(_ index: Int?) {
        hover = index.map { Hover(folder: store.current.id, index: $0) }
    }

    var body: some View {
        let arcs = store.sunburstArcs
        let hovered = hoveredIndex(arcs)
        // Shallow trees get thicker rings instead of leaving the outer rings empty.
        let depthCount = max(2, arcs.lazy.map(\.depth).max() ?? 1)
        HStack(alignment: .top, spacing: 30) {
            GeometryReader { proxy in
                let rings = RingGeometry(size: proxy.size, depthCount: depthCount)
                ZStack {
                    SunburstCanvas(arcs: arcs, rings: rings, hovered: hovered, selectedID: store.selected?.id,
                                   holeHighlighted: hovered == -1 && !store.navigation.isEmpty,
                                   progress: progress, lift: lift)
                    centerLabel(arcs: arcs, hovered: hovered).frame(width: rings.inner * 1.6).position(rings.center)
                        .id(store.current.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): setHover(rings.index(at: point, in: arcs))
                    case .ended: setHover(nil)
                    }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    guard let index = rings.index(at: point, in: arcs) else { return }
                    if index == -1 { store.goBack(); return }
                    guard let node = arcs[index].node else { store.showMap = false; return }
                    setHover(nil)
                    if node.isDirectory { store.enter(node) } else { store.selected = node }
                }
                .contextMenu { if let index = hovered, index >= 0, let node = arcs[index].node { NodeMenu(node: node) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("map.title"))
            }
            .frame(height: 340)
            .frame(maxWidth: .infinity)

            legend(arcs: arcs, hovered: hovered).frame(width: 280)
                .id(store.current.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: store.current.id)
        .onAppear(perform: sweepIn)
        .onChange(of: store.current.id) { sweepIn() }
        .onChange(of: hover) { _, new in
            guard new != nil else { withAnimation(.easeOut(duration: 0.15)) { lift = 0 }; return }
            reset { lift = 0 }
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { lift = 1 }
        }
    }

    private func sweepIn() {
        reset { progress = 0 }
        // Next runloop turn, so the reset frame is committed before the sweep starts.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.65)) { progress = 1 }
        }
    }

    private func reset(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    @ViewBuilder private func centerLabel(arcs: [SunburstArc], hovered: Int?) -> some View {
        let current = store.current
        let arc = hovered.flatMap { $0 >= 0 ? arcs[$0] : nil }
        VStack(spacing: 3) {
            if let arc {
                Text(arc.node?.name ?? L10n.text("map.smaller")).font(.system(size: 10, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(SizeText.format(arc.size)).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("\(percentage(arc.size, current.size))%").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            } else {
                Text(current.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(SizeText.format(current.size)).font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                if !store.navigation.isEmpty {
                    Label(L10n.text("map.up"), systemImage: "arrow.up").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .minimumScaleFactor(0.7)
    }

    @ViewBuilder private func legend(arcs: [SunburstArc], hovered: Int?) -> some View {
        let current = store.current
        let top = arcs.enumerated().filter { $0.element.depth == 1 && $0.element.node != nil }.prefix(10)
        let shown = top.reduce(Int64(0)) { $0 + $1.element.size }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(Theme.accent).frame(width: 11, height: 11)
                Text(current.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(SizeText.format(current.size)).font(.system(size: 15, weight: .semibold, design: .rounded))
            }.padding(.bottom, 12)
            ForEach(Array(top), id: \.offset) { index, arc in
                if let node = arc.node {
                    Button {
                        if node.isDirectory { store.enter(node) } else { store.selected = node }
                    } label: {
                        HStack(spacing: 9) {
                            Circle().fill(Self.color(for: arc)).frame(width: 8, height: 8)
                            Image(systemName: node.kind.symbol).font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 14)
                            Text(node.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(SizeText.format(node.size)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 6)
                        .background(hovered == index ? Theme.background : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { setHover(index) } else if hovered == index { setHover(nil) }
                    }
                    .contextMenu { NodeMenu(node: node) }
                }
            }
            if current.size > shown && current.size - shown > 0 {
                HStack(spacing: 9) {
                    Circle().fill(Theme.line).frame(width: 8, height: 8)
                    Color.clear.frame(width: 14, height: 1)
                    Text(L10n.text("map.smaller")).font(.system(size: 12))
                    Spacer(minLength: 6)
                    Text(SizeText.format(current.size - shown)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                }.foregroundStyle(Theme.secondary).padding(.vertical, 5).padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
    }

    /// Hue follows the arc's angle (as in DaisyDisk), so neighbours stay distinguishable
    /// even when one folder dominates; deeper rings get lighter. Muted to suit the theme.
    static func color(for arc: SunburstArc) -> Color {
        guard arc.node != nil else { return Theme.line }
        let middle = (arc.start + arc.end) / 2 / (2 * .pi)
        let depth = Double(arc.depth - 1)
        return Color(hue: (0.04 + middle * 0.92).truncatingRemainder(dividingBy: 1),
                     saturation: max(0.18, 0.5 - depth * 0.07), brightness: min(0.95, 0.8 + depth * 0.035))
    }
}

/// Draws the rings; `Animatable` lets SwiftUI interpolate the sweep and hover lift frame by frame.
private struct SunburstCanvas: View, Animatable {
    let arcs: [SunburstArc]
    let rings: RingGeometry
    let hovered: Int?
    let selectedID: String?
    let holeHighlighted: Bool
    var progress: Double
    var lift: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, lift) }
        set { progress = newValue.first; lift = newValue.second }
    }

    var body: some View {
        Canvas { context, _ in
            var selectedPath: Path?
            var hoveredPath: Path?
            for (index, arc) in arcs.enumerated() {
                // Outer rings start a little later, so the chart unfolds from the centre.
                let local = min(1, max(0, progress * 1.5 - Double(arc.depth - 1) * 0.12))
                guard local > 0 else { continue }
                let eased = 1 - pow(1 - local, 3)
                let isHovered = index == hovered
                let path = rings.path(arc, sweep: eased, grow: eased, lift: isHovered ? lift * 7 : 0)
                if isHovered { hoveredPath = path; continue }
                context.fill(path, with: .color(SunburstView.color(for: arc)))
                context.stroke(path, with: .color(.white), lineWidth: 1)
                if let selectedID, arc.node?.id == selectedID { selectedPath = path }
            }
            if let selectedPath { context.stroke(selectedPath, with: .color(Theme.ink), lineWidth: 2) }
            // The hovered slice is drawn last so its lifted edge sits above its neighbours.
            if let hoveredPath, let hovered {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.18 * lift), radius: 6 * lift, y: 2 * lift))
                    layer.fill(hoveredPath, with: .color(SunburstView.color(for: arcs[hovered])))
                }
                context.fill(hoveredPath, with: .color(.black.opacity(0.08 * lift)))
                context.stroke(hoveredPath, with: .color(.white), lineWidth: 1.5)
            }
            let radius = rings.inner - 3
            let hole = Path(ellipseIn: CGRect(x: rings.center.x - radius, y: rings.center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(hole, with: .color(holeHighlighted ? Theme.sidebar : Theme.background))
        }
    }
}

private struct RingGeometry {
    let center: CGPoint
    let inner: CGFloat
    let ring: CGFloat
    let depthCount: Int

    init(size: CGSize, depthCount: Int) {
        let outer = max(10, min(size.width, size.height) / 2 - 4)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        inner = outer * 0.3
        ring = (outer - inner) / CGFloat(depthCount)
        self.depthCount = depthCount
    }

    /// `sweep` scales angles from twelve o'clock, `grow` scales the ring's thickness,
    /// and `lift` pushes the outer edge outward in points.
    func path(_ arc: SunburstArc, sweep: Double = 1, grow: Double = 1, lift: CGFloat = 0) -> Path {
        let lower = inner + ring * CGFloat(arc.depth - 1) * CGFloat(grow)
        let upper = lower + ring * CGFloat(grow) + lift
        let start = Angle(radians: arc.start * sweep - .pi / 2)
        let end = Angle(radians: arc.end * sweep - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: upper, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: lower, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Index of the arc under `point`, -1 for the centre hole, nil for empty space.
    func index(at point: CGPoint, in arcs: [SunburstArc]) -> Int? {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let radius = CGFloat((dx * dx + dy * dy).squareRoot())
        if radius < inner { return -1 }
        let depth = Int((radius - inner) / ring) + 1
        guard depth <= depthCount else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return arcs.firstIndex { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
}
