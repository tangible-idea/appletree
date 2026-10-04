import AppKit

@MainActor
enum AppIcon {
    static func apply() {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("AppleTree.icns")
        let resource = packaged.flatMap { NSImage(contentsOf: $0) }
            ?? Bundle.module.url(forResource: "AppleTree", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if let resource { NSApplication.shared.applicationIconImage = resource }
    }
}
