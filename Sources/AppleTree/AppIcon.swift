import AppKit

@MainActor
enum AppIcon {
    static func apply() {
        #if SWIFT_PACKAGE
        let moduleIcon = Bundle.module.url(forResource: "AppleTree", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        #else
        let moduleIcon: NSImage? = nil
        #endif
        let packaged = Bundle.main.url(forResource: "AppleTree", withExtension: "icns")
            ?? Bundle.main.resourceURL?.appendingPathComponent("AppleTree.icns")
        let resource = packaged.flatMap { NSImage(contentsOf: $0) } ?? moduleIcon
        if let resource { NSApplication.shared.applicationIconImage = resource }
    }
}
