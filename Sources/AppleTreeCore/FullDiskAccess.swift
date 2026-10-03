import Foundation
import AppKit

public enum FullDiskAccess {
    public static var isGranted: Bool {
        // In macOS, ~/Library/Safari is strictly protected by TCC.
        // Without Full Disk Access, reading this folder fails with POSIX error 1 (EPERM / Operation not permitted).
        let safariURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
        do {
            _ = try FileManager.default.contentsOfDirectory(at: safariURL, includingPropertiesForKeys: nil)
            return true
        } catch {
            return false
        }
    }

    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func revealAppInFinder() {
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }
}
