#if DEBUG
import AppKit
import SwiftUI
import AppleTreeCore

/// Development-only integration checks and capture of the app's own window.
@MainActor
enum AppDiagnostics {
    static func runIfRequested(store: AppStore) {
        let args = CommandLine.arguments
        guard args.contains("--snapshot") || args.contains("--smoke-test") else { return }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
                if let index = args.firstIndex(of: "--expect-language"), args.count > index + 1 {
                    try require(L10n.language == args[index + 1], "Unexpected language: \(L10n.language)")
                    try require(L10n.text("action.scan") != "action.scan", "Missing language resources")
                }
                print("App language: \(L10n.language); scan button: \(L10n.text("action.scan"))")
                if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
                    guard let view = NSApplication.shared.windows.first(where: { $0.isVisible })?.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw DiagnosticError.failed("Window capture unavailable")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw DiagnosticError.failed("PNG creation failed")
                    }
                    try png.write(to: URL(fileURLWithPath: args[index + 1]))
                    print("Snapshot saved: \(args[index + 1])")
                }
                if args.contains("--smoke-test") {
                    try await smokeTest(store)
                    print("App integration checks passed: scan, navigation, search, largest files, refresh, cancellation, error recovery.")
                }
                // An error sheet may veto the normal Cocoa quit request in the
                // error-recovery check. A completed diagnostic must exit reliably.
                exit(0)
            } catch {
                print("App diagnostics FAILED: \(error)")
                exit(1)
            }
        }
    }

    private static func smokeTest(_ store: AppStore) async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(repeating: 1, count: 200).write(to: fixture.appendingPathComponent("Nested/movie.mp4"))
        try Data(repeating: 2, count: 50).write(to: fixture.appendingPathComponent("note.txt"))
        store.scan(fixture)
        try await waitForScan(store)
        try require(!store.isDemo && store.root.size == 250, "Real folder scan failed")
        try require(store.visibleItems.count == 2, "Folder listing failed")
        store.enter(store.root.children[0])
        try require(store.current.name == "Nested" && store.visibleItems.count == 1, "Folder navigation failed")
        store.mode = .largest
        try require(store.visibleItems.first?.name == "movie.mp4", "Scoped files failed")
        store.goBack()
        store.query = "NOTE"
        try require(store.visibleItems.first?.name == "note.txt" && store.matchingCount == 1, "Search failed")
        store.query = ""
        try require(store.visibleItems.map(\.size) == [200, 50], "Largest files order failed")
        store.refresh()
        try await waitForScan(store)
        try require(store.root.size == 250, "Refresh failed")
        store.scan(fixture)
        store.cancelScan()
        try require(!store.isScanning && store.root.size == 250, "Cancellation lost previous results")
        store.scan(fixture.appendingPathComponent("does-not-exist"))
        try await waitForScan(store)
        try require(store.errorMessage != nil && store.root.size == 250, "Error recovery lost previous results")
    }

    private static func waitForScan(_ store: AppStore) async throws {
        for _ in 0..<100 {
            if !store.isScanning { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DiagnosticError.failed("Scan timed out")
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw DiagnosticError.failed(message) }
    }

    private enum DiagnosticError: Error { case failed(String) }
}
#endif
