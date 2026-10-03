import Foundation

public struct SunburstArc: Sendable {
    /// `nil` for the grey segment that stands in for items too thin to draw.
    public let node: FileNode?
    public let depth: Int
    /// Radians, clockwise from twelve o'clock.
    public let start: Double
    public let end: Double
    public let size: Int64

    public var span: Double { end - start }
}

/// Radial (DaisyDisk-style) layout: each ring is one folder level and every
/// arc's angle is proportional to bytes within its parent's angle.
public enum Sunburst {
    public static func layout(root: FileNode, maxDepth: Int = 5, minAngle: Double = 0.008) -> [SunburstArc] {
        guard root.size > 0 else { return [] }
        var arcs: [SunburstArc] = []

        func place(_ node: FileNode, start: Double, end: Double, depth: Int) {
            guard node.size > 0, depth <= maxDepth else { return }
            var cursor = start
            var restSize: Int64 = 0
            let scale = (end - start) / Double(node.size)
            for child in node.children where child.size > 0 {
                let span = Double(child.size) * scale
                if span < minAngle {
                    restSize += child.size
                    continue
                }
                arcs.append(SunburstArc(node: child, depth: depth, start: cursor, end: cursor + span,
                                        size: child.size))
                if child.isDirectory {
                    place(child, start: cursor, end: cursor + span, depth: depth + 1)
                }
                cursor += span
            }
            if restSize > 0 {
                arcs.append(SunburstArc(node: nil, depth: depth, start: cursor, end: min(end, cursor + Double(restSize) * scale),
                                        size: restSize))
            }
        }

        place(root, start: 0, end: 2 * .pi, depth: 1)
        return arcs
    }
}
