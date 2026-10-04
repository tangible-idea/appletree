import AppKit

// Render at an exact pixel size, independent of the Mac's display scale.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let background = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.90, alpha: 1).setFill()
background.fill()
let trunk = NSBezierPath(roundedRect: NSRect(x: 478, y: 245, width: 68, height: 405), xRadius: 30, yRadius: 30)
NSColor(calibratedRed: 0.29, green: 0.38, blue: 0.29, alpha: 1).set()
trunk.fill()
let leftBranch = NSBezierPath()
leftBranch.move(to: NSPoint(x: 510, y: 420))
leftBranch.line(to: NSPoint(x: 365, y: 555))
leftBranch.lineWidth = 48
leftBranch.lineCapStyle = .round
leftBranch.stroke()
let rightBranch = NSBezierPath()
rightBranch.move(to: NSPoint(x: 515, y: 485))
rightBranch.line(to: NSPoint(x: 660, y: 620))
rightBranch.lineWidth = 48
rightBranch.lineCapStyle = .round
rightBranch.stroke()
for (x, y, radius, color) in [
    (365.0, 605.0, 149.0, NSColor(calibratedRed: 0.86, green: 0.45, blue: 0.29, alpha: 1)),
    (641.0, 668.0, 142.0, NSColor(calibratedRed: 0.89, green: 0.64, blue: 0.35, alpha: 1)),
    (485.0, 752.0, 119.0, NSColor(calibratedRed: 0.53, green: 0.62, blue: 0.49, alpha: 1))
] {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
