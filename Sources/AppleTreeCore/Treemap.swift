import Foundation
import CoreGraphics

public struct MapRect: Sendable {
    public let index: Int
    public let rect: CGRect
}

/// Squarified treemap: tile area is proportional to bytes, with no minimum-area distortion.
public enum Treemap {
    public static func layout(weights: [Int64], in bounds: CGRect) -> [MapRect] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let positive = weights.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }
        let total = positive.reduce(0.0) { $0 + Double($1.element) }
        guard total > 0 else { return [] }
        var remaining = bounds
        var row: [(index: Int, area: Double)] = []
        var output: [MapRect] = []

        func worst(_ items: [(index: Int, area: Double)], side: Double) -> Double {
            guard !items.isEmpty, side > 0 else { return .infinity }
            let sum = items.reduce(0) { $0 + $1.area }
            let smallest = items.map(\.area).min()!
            let largest = items.map(\.area).max()!
            return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
        }

        func place(_ items: [(index: Int, area: Double)]) {
            let sum = items.reduce(0) { $0 + $1.area }
            if remaining.width >= remaining.height {
                let width = min(remaining.width, sum / remaining.height)
                var y = remaining.minY
                for item in items {
                    let height = item.area / width
                    output.append(MapRect(index: item.index, rect: CGRect(x: remaining.minX, y: y, width: width, height: height)))
                    y += height
                }
                remaining.origin.x += width
                remaining.size.width = max(0, remaining.width - width)
            } else {
                let height = min(remaining.height, sum / remaining.width)
                var x = remaining.minX
                for item in items {
                    let width = item.area / height
                    output.append(MapRect(index: item.index, rect: CGRect(x: x, y: remaining.minY, width: width, height: height)))
                    x += width
                }
                remaining.origin.y += height
                remaining.size.height = max(0, remaining.height - height)
            }
        }

        for item in positive {
            let next = (index: item.offset, area: Double(item.element) / total * Double(bounds.width * bounds.height))
            let side = min(remaining.width, remaining.height)
            if !row.isEmpty && worst(row + [next], side: side) > worst(row, side: side) {
                place(row)
                row = []
            }
            row.append(next)
        }
        if !row.isEmpty { place(row) }
        return output
    }
}
