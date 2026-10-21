#if DEBUG
import AppKit
import Combine
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
        try await cacheBudgetSmokeTest()
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
        let discoveries = ["→ App caches, 2.7MB dry", "→ Old logs, 500KB dry"]
        let body = "#!/bin/bash\n[ \"$1\" = clean ] && [ \"$2\" = --dry-run ] || exit 4\nprintf '%s\\n' "
            + discoveries.map(quote).joined(separator: " ") + "\nsleep 2\nprintf '%s\\n' "
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
        for _ in 0..<100 {
            if cleanup.findings.count == 2 || !cleanup.isBusy { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(cleanup.phase == .discovering && cleanup.findings.count == 2, "Discoveries were not streamed while Finding was still running")
        try require(cleanup.findings.map(\.size) == ["2.7MB", "500KB"], "Discovery estimates were lost or repeated")
        try require(cleanup.removedBytes == 0 && cleanup.result == nil, "Discovery estimates or old history were presented as current removals")
        try require(FileManager.default.fileExists(atPath: cache.path), "Discovery deleted a file")
        for _ in 0..<600 {
            if !cleanup.isBusy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(!cleanup.isBusy, "Cleanup timed out")
        try require(cleanup.errorMessage == nil, "Cleanup failed: \(cleanup.errorMessage ?? "")")
        try require(cleanup.result?.removedBytes == 2_500_000, "Cleanup removed unexpected bytes")
        try require(cleanup.result?.removedFiles == 2, "Cleanup removed unexpected file count")
        try require(cleanup.planComplete && cleanup.plannedBytes == 2_500_000, "Verified size includes recent or protected files")
        try require(cleanup.result?.plannedBytes == cleanup.plannedBytes, "Saved plan differs from the live total")
        try require(cleanup.removedBytes == cleanup.result?.removedBytes && cleanup.removedFiles == 2, "Live removal total differs from the result")
        try require(cleanup.logEntries.count == 2 && cleanup.logEntries.allSatisfy {
            if case .removed = $0.status { return true }; return false
        }, "Successful deletion logs were lost")
        try require(cleanup.logEntries.reduce(0) { $0 + $1.file.size } == cleanup.plannedBytes, "Log file sizes differ from the verified total")
        try require(!FileManager.default.fileExists(atPath: cache.path) && !FileManager.default.fileExists(atPath: log.path), "Old cache/log not removed")
        try require(FileManager.default.fileExists(atPath: recent.path) && FileManager.default.fileExists(atPath: key.path), "Cleanup lost protected files")
        try require(refreshed && store.root.size < before, "Cleanup did not refresh the space map")
        let records = try JSONDecoder().decode([CleanupResult].self, from: Data(contentsOf: historyURL))
        try require(records.first?.removedBytes == 2_500_000 && cleanup.configured, "Cleanup history or settings not saved")
        try cleanupLogIsolationSmokeTest(files: cleanup.logEntries.map(\.file), home: canonicalHome, defaults: defaults, script: script)
        print("Cleanup integration passed: fake Mole preview, 2 fixture files removed, recent/key files kept, map refreshed, history saved.")
        return cleanup
    }

    private static func cleanupLogIsolationSmokeTest(files: [CleanupFile], home: URL, defaults: UserDefaults, script: URL) throws {
        let probe = CleanupStore(defaults: defaults, historyURL: home.appendingPathComponent("unused-history.json"), home: home, executable: script)
        let log = probe.log
        var parentUpdates = 0
        var membershipUpdates = 0
        let parent = probe.objectWillChange.sink { parentUpdates += 1 }
        let membership = log.$entries.dropFirst().sink { _ in membershipUpdates += 1 }
        log.apply(files.map { .found($0) })
        try require(parentUpdates == 0 && membershipUpdates == 1, "Log discovery invalidated the main browser or republished membership repeatedly")
        let first = log.entries[0]
        var firstUpdates = 0
        var otherUpdates = 0
        let firstRow = first.objectWillChange.sink { firstUpdates += 1 }
        let otherRow = log.entries[1].objectWillChange.sink { otherUpdates += 1 }
        log.apply([.execution(.removing(files[0])), .execution(.finished(files[0], skipped: nil))])
        try require(first === log.entries[0] && firstUpdates == 2 && otherUpdates == 0, "A file update replaced or invalidated unrelated rows")
        try require(parentUpdates == 0 && membershipUpdates == 1, "A status update republished the full file list or browser")
        try require(log.summary.removedBytes == files[0].size && log.summary.removedFiles == 1, "Batched removal lost its size")
        log.apply([.execution(.finished(files[0], skipped: nil)), .execution(.finished(files[1], skipped: .inUse))])
        try require(log.summary.processedFiles == 2 && log.summary.removedFiles == 1, "A duplicate or skipped event inflated removal totals")
        try require(log.focusedEntryID == files[1].url.path, "Log focus requires searching the full list")
        withExtendedLifetime((parent, membership, firstRow, otherRow)) {}

        var delivered: [CleanupUpdate] = []
        let reporter = CleanupReporter { delivered += $0 }
        for index in 0..<10_000 { reporter.send(.detail(String(index))) }
        reporter.send(.found(files[0]))
        reporter.send(.execution(.finished(files[0], skipped: nil)))
        reporter.flush()
        try require(delivered.count == 3, "Transient paths were not coalesced, or a file event was dropped")
        if case .detail(let text) = delivered.last {
            try require(text == "9999", "The latest path was lost")
        } else { throw DiagnosticError.failed("The latest path was not delivered") }
        print("Log update isolation passed: no browser or membership updates during deletion, only the changed row notified, 10,000 transient paths coalesced.")
    }

    private static func cacheBudgetSmokeTest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-cache-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ScanIndexCache(directory: directory, nodeLimit: 3, reportLimit: 2)
        func report(_ name: String, files: Int) -> ScanReport {
            let url = directory.appendingPathComponent(name)
            let children = (0..<files).map { FileNode(url: url.appendingPathComponent("file-\($0)"), isDirectory: false, size: 10) }
            return ScanReport(root: FileNode(url: url, isDirectory: true, size: Int64(files * 10), children: children))
        }
        let large = report("large", files: 3)
        cache.set(large, for: large.root.url)
        try require(cache.memoryReportCount == 0, "An oversized tree was retained in memory cache")
        let active = await cache.findNodeInCachedTrees(for: large.root.children[0].url, activeReport: large)
        try require(active?.report.root === large.root && active?.node === large.root.children[0], "The active oversized tree was reloaded or lost")
        let first = report("first", files: 1)
        let second = report("second", files: 1)
        cache.set(first, for: first.root.url)
        cache.set(second, for: second.root.url)
        try require(cache.memoryReportCount == 1 && cache.memoryNodeCount == 2, "The retained tree budget was exceeded")
        var reloaded: ScanReport?
        for _ in 0..<100 {
            reloaded = await cache.get(for: first.root.url)
            if reloaded != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(reloaded?.isCached == true && reloaded?.root.size == first.root.size, "Eviction removed the disk archive")
        try require(reloaded?.root !== first.root && cache.memoryNodeCount <= 3, "Eviction did not reload from disk within budget")
        var reloadedLarge: ScanReport?
        for _ in 0..<100 {
            reloadedLarge = await cache.get(for: large.root.url)
            if reloadedLarge != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(reloadedLarge?.root.nodeCount == 4 && cache.memoryNodeCount <= 3, "An oversized archive could not be reopened within budget")
        let childURL = directory.appendingPathComponent("parent/child")
        let oldChild = FileNode(url: childURL, isDirectory: true, size: 10)
        let ancestor = ScanReport(root: FileNode(url: childURL.deletingLastPathComponent(), isDirectory: true, size: 10, children: [oldChild]))
        let fresh = ScanReport(root: FileNode(url: childURL, isDirectory: true, size: 20))
        cache.set(fresh, for: childURL)
        let latest = await cache.findNodeInCachedTrees(for: childURL, activeReport: ancestor)
        try require(latest?.node === fresh.root, "Active ancestor hid a newer exact cached scan")
        print("Cache budget integration passed: oversized active tree reused, evicted archives reloaded, retained nodes stayed within budget.")
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
