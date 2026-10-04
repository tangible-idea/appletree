#if DEBUG
import AppKit
import SwiftUI
import AppleTreeCore

/// Development-only integration checks and capture of the app's own window.
@MainActor
enum AppDiagnostics {
    private static var started = false
    static func runIfRequested(store: AppStore) {
        let args = CommandLine.arguments
        guard args.contains("--snapshot") || args.contains("--smoke-test") else { return }
        guard !started else { return }
        started = true
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
                try require(NSApplication.shared.activationPolicy() == .accessory, "Diagnostics must not add a Dock icon")
                var diagnosticWindow: NSWindow?
                // Direct CLI launches can restore a session without an initial WindowGroup window.
                if !NSApplication.shared.windows.contains(where: { $0.isVisible }) {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 920),
                                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.contentView = NSHostingView(rootView: ContentView().environmentObject(store).environmentObject(store.cleanup).preferredColorScheme(.light))
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    diagnosticWindow = window
                }
                defer { diagnosticWindow?.orderOut(nil) }
                if let index = args.firstIndex(of: "--expect-language"), args.count > index + 1 {
                    try require(L10n.language == args[index + 1], "Unexpected language: \(L10n.language)")
                    try require(L10n.text("action.scan") != "action.scan", "Missing language resources")
                }
                print("App language: \(L10n.language); scan button: \(L10n.text("action.scan"))")
                var cleanupWindow: NSWindow?
                if args.contains("--cleanup-result-snapshot") {
                    let cleanup = try await cleanupSmokeTest(store)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 680),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.contentView = NSHostingView(rootView: CleanupSheet().environmentObject(store).environmentObject(cleanup))
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    cleanupWindow = window
                    try await Task.sleep(for: .milliseconds(700))
                } else if args.contains("--cleanup-snapshot") {
                    store.cleanup.showSheet = true
                    try await Task.sleep(for: .milliseconds(700))
                }
                if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
                    let window = cleanupWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.sheetParent != nil })
                        ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                    guard let view = window?.contentView,
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
                    print("App integration checks passed: scan, navigation, search, extension/regex search, zip export, largest files, refresh, cancellation, error recovery, scoped cleanup, history, cleanup map refresh.")
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
        await store.waitForSearch()
        try require(store.visibleItems.first?.name == "movie.mp4", "Scoped files failed")
        store.goBack()
        await store.waitForSearch()
        store.query = "NOTE"
        await store.waitForSearch()
        try require(store.visibleItems.first?.name == "note.txt" && store.matchingCount == 1, "Search failed")
        store.query = ""
        await store.waitForSearch()
        try require(store.visibleItems.map(\.size) == [200, 50], "Largest files order failed")
        store.mode = .folders
        store.kindFilter = [.video]
        await store.waitForSearch()
        try require(store.visibleItems.map(\.name) == ["movie.mp4"], "Kind filter failed")
        store.clearFilters()
        store.toggleExpanded(store.root.children[0])
        try require(store.outlineRows.map(\.node.name) == ["Nested", "movie.mp4", "note.txt"], "Outline expansion failed")
        try require(!store.sunburstArcs.isEmpty, "Ring chart layout failed")
        store.searchMode = .ext
        store.query = "mp4 txt"
        await store.waitForSearch()
        try require(store.matchingCount == 2, "Extension search failed")
        store.searchMode = .regex
        store.query = "^(movie|note)\\."
        await store.waitForSearch()
        try require(store.matchingCount == 2, "Regex search failed")
        let roots = SearchIndex(root: store.root).exportRoots(store.searchQuery, in: store.root)
        // Outside the fixture, so the later refresh check still sees the original 250 bytes.
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-export-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await ArchiveExporter.zip(roots, base: store.root.url, to: archive) { _ in }
        let listing = Process()
        let output = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        listing.arguments = ["-tf", archive.path]
        listing.standardOutput = output
        try listing.run()
        listing.waitUntilExit()
        let names = Set(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init))
        try require(names == ["Nested/movie.mp4", "note.txt"], "Zip export failed: \(names)")
        store.query = "(["
        await store.waitForSearch()
        try require(store.results.invalidPattern, "Invalid regex not reported")
        store.searchMode = .name
        store.query = ""
        store.mode = .largest
        store.refresh()
        try await waitForScan(store)
        try require(store.root.size == 250, "Refresh failed")
        store.scan(fixture)
        store.cancelScan()
        try require(!store.isScanning && store.root.size == 250, "Cancellation lost previous results")
        store.scan(fixture.appendingPathComponent("does-not-exist"))
        try await waitForScan(store)
        try require(store.errorMessage != nil && store.root.size == 250, "Error recovery lost previous results")
        store.errorMessage = nil
        _ = try await cleanupSmokeTest(store)
    }

    /// Runs the complete cleanup flow with a fake Mole preview and a disposable home directory.
    /// The activity collectors remain real; no real user cache is eligible for deletion.
    private static func cleanupSmokeTest(_ store: AppStore) async throws -> CleanupStore {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-cleanup-ui-\(UUID().uuidString)")
        let home = fixture.appendingPathComponent("Home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let canonicalHome = SmartCleanup(home: home).home
        func make(_ path: String, size: Int, old: Bool = true) throws -> URL {
            let url = canonicalHome.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: size).write(to: url)
            if old { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100 * 86_400)], ofItemAtPath: url.path) }
            return url
        }
        let cache = try make("Library/Caches/com.fixture.cache/old.bin", size: 2_000_000)
        let log = try make("Library/Logs/fixture/old.log", size: 500_000)
        let recent = try make("Library/Caches/com.fixture.cache/recent.bin", size: 700_000, old: false)
        let key = try make("Library/Caches/com.fixture.cache/private.pem", size: 300)
        let previewFolder = canonicalHome.appendingPathComponent(".config/mole")
        try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = fixture.appendingPathComponent("fake-mole.sh")
        let preview = ["# Mole Cleanup Preview - fixture", cache.deletingLastPathComponent().path + "  # 2.7MB", log.path + "  # 500KB"]
        let body = "#!/bin/bash\n[ \"$1\" = clean ] && [ \"$2\" = --dry-run ] || exit 4\nprintf '%s\\n' "
            + preview.map(quote).joined(separator: " ") + " > " + quote(previewFolder.appendingPathComponent("clean-list.txt").path) + "\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let suite = "AppleTree-cleanup-diagnostic-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw DiagnosticError.failed("Could not create diagnostic preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyURL = fixture.appendingPathComponent("history.json")
        let cleanup = CleanupStore(defaults: defaults, historyURL: historyURL, home: canonicalHome, executable: script)
        store.scan(home, force: true)
        try await waitForScan(store)
        let before = store.root.size
        var refreshed = false
        cleanup.start {
            await store.refreshAfterCleanup(invalidateCache: false)
            refreshed = true
        }
        for _ in 0..<600 {
            if !cleanup.isBusy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(!cleanup.isBusy, "Cleanup timed out")
        try require(cleanup.errorMessage == nil, "Cleanup failed: \(cleanup.errorMessage ?? "")")
        try require(cleanup.result?.removedBytes == 2_500_000, "Cleanup removed unexpected bytes")
        try require(cleanup.result?.removedFiles == 2, "Cleanup removed unexpected file count")
        try require(!FileManager.default.fileExists(atPath: cache.path) && !FileManager.default.fileExists(atPath: log.path), "Old cache/log not removed")
        try require(FileManager.default.fileExists(atPath: recent.path) && FileManager.default.fileExists(atPath: key.path), "Cleanup lost protected files")
        try require(refreshed && store.root.size < before, "Cleanup did not refresh the space map")
        let records = try JSONDecoder().decode([CleanupResult].self, from: Data(contentsOf: historyURL))
        try require(records.first?.removedBytes == 2_500_000 && cleanup.configured, "Cleanup history or settings not saved")
        print("Cleanup integration passed: fake Mole preview, 2 fixture files removed, recent/key files kept, map refreshed, history saved.")
        return cleanup
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
