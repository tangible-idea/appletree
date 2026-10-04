import Foundation
import Darwin
import Testing
@testable import AppleTreeCore

private struct CleanupFixture {
    let home: URL
    init() throws {
        let temporary = FileManager.default.temporaryDirectory
        let resolved = try #require(realpath(temporary.path, nil))
        defer { free(resolved) }
        home = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("AppleTree-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    func file(_ path: String, size: Int = 100, old: Bool = true) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: size).write(to: url)
        if old { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100 * 86_400)], ofItemAtPath: url.path) }
        return url
    }
    var cleaner: SmartCleanup { SmartCleanup(home: home) }
}

@Test func cleanupDeletesOnlySelectedOldCacheAndLogFiles() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let cache = try fixture.file("Library/Caches/com.example/cache.bin", size: 120)
    let log = try fixture.file("Library/Logs/example/old.log", size: 30)
    let recent = try fixture.file("Library/Caches/com.example/recent.bin", old: false)
    let download = try fixture.file("Downloads/old.dmg")
    let trash = try fixture.file(".Trash/old.log")
    let preferences = try fixture.file("Library/Preferences/config.plist")
    let unsupported = try fixture.file("Library/Logs/example/notes.txt")
    let plan = try fixture.cleaner.plan(paths: [fixture.home.appendingPathComponent("Library/Caches"), log, download, trash, preferences, unsupported],
                                        settings: CleanupSettings(), activity: CleanupActivity())
    #expect(Set(plan.files.map(\.url)) == [cache, log])
    let result = fixture.cleaner.execute(plan, activity: CleanupActivity())
    #expect(result.removedFiles == 2)
    #expect(result.removedBytes == 150)
    #expect(result.before[.appCaches] == 220)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(!FileManager.default.fileExists(atPath: log.path))
    for kept in [recent, download, trash, preferences, unsupported] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
    let decoded = try JSONDecoder().decode(CleanupResult.self, from: JSONEncoder().encode(result))
    #expect(decoded.removedBytes == 150)
    #expect(decoded.skipped[.recent] == 1)
}

@Test func cleanupProtectsSensitiveDataAndExcludedFolders() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let names = ["key.pem", ".env", "model.gguf", "cache.db", ".git/objects/data", "Models/data.bin", "Offline/data.bin", "AppleTree/index.atix", "mole/state", "protected/data.bin"]
    for name in names { _ = try fixture.file("Library/Caches/" + name) }
    var settings = CleanupSettings()
    settings.protectedPaths = [fixture.home.appendingPathComponent("Library/Caches/protected").path]
    let plan = try fixture.cleaner.plan(paths: [fixture.home.appendingPathComponent("Library/Caches")], settings: settings, activity: CleanupActivity())
    #expect(plan.files.isEmpty)
    #expect((plan.skipped[.protected] ?? 0) >= names.count)
}

@Test func cleanupKeepsMoleWhitelistDescendantsAndWildcards() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    _ = try fixture.file("Library/Caches/com.example/keep/file.bin")
    _ = try fixture.file("Library/Caches/com.protected/file.bin")
    let okay = try fixture.file("Library/Caches/com.example/remove.bin")
    let patterns = [fixture.home.path + "/Library/Caches/com.example/keep", fixture.home.path + "/Library/Caches/com.prot*"]
    let plan = try fixture.cleaner.plan(paths: [fixture.home.appendingPathComponent("Library/Caches")], settings: CleanupSettings(), activity: CleanupActivity(), moleProtection: patterns)
    #expect(plan.files.map(\.url) == [okay])
}

@Test func cleanupDeduplicatesGroupedPreviewAndSeparatesToolScope() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let app = try fixture.file("Library/Caches/com.example/cache.bin")
    let tool = try fixture.file("Library/Caches/Homebrew/downloads/pkg.bin")
    var settings = CleanupSettings()
    settings.categories = [.toolCaches]
    let plan = try fixture.cleaner.plan(paths: [fixture.home.appendingPathComponent("Library/Caches"), tool, tool, app], settings: settings, activity: CleanupActivity())
    #expect(plan.files.map(\.url) == [tool])
    #expect(plan.eligibleBytes == 100)
    let defaultPlan = try fixture.cleaner.plan(paths: [fixture.home.appendingPathComponent("Library/Caches")], settings: CleanupSettings(), activity: CleanupActivity())
    #expect(defaultPlan.files.map(\.url) == [app])
}

@Test func cleanupSkipsRunningAppsOpenFilesAndBusyTools() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    _ = try fixture.file("Library/Caches/com.example.live/data.bin")
    let opened = try fixture.file("Library/Caches/closed/open.bin")
    _ = try fixture.file(".npm/_cacache/content.bin")
    var settings = CleanupSettings()
    settings.categories = Set(CleanupCategory.allCases)
    let activity = CleanupActivity(openPaths: [opened.path], appIdentifiers: ["com.example.live"], busyTools: ["node"])
    let plan = try fixture.cleaner.plan(paths: [fixture.home.appendingPathComponent("Library/Caches"), fixture.home.appendingPathComponent(".npm/_cacache")], settings: settings, activity: activity)
    #expect(plan.files.isEmpty)
    #expect(plan.skipped[.inUse] == 3)
}

@Test func cleanupNeverFollowsLinksOrRemovesHardlinkedFiles() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let outside = try fixture.file("Documents/original.bin")
    let directory = fixture.home.appendingPathComponent("Library/Caches/example")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.bin"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias-folder"), withDestinationURL: outside.deletingLastPathComponent())
    try FileManager.default.linkItem(at: outside, to: directory.appendingPathComponent("hard.bin"))
    let plan = try fixture.cleaner.plan(paths: [directory, directory.appendingPathComponent("alias-folder/original.bin")], settings: CleanupSettings(), activity: CleanupActivity())
    #expect(plan.files.isEmpty)
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test func cleanupRevalidatesModifiedAndReplacedFiles() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let changed = try fixture.file("Library/Caches/example/changed.bin")
    let replaced = try fixture.file("Library/Caches/example/replaced.bin")
    let plan = try fixture.cleaner.plan(paths: [changed, replaced], settings: CleanupSettings(), activity: CleanupActivity())
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: changed.path)
    try FileManager.default.moveItem(at: replaced, to: replaced.appendingPathExtension("old"))
    try Data(repeating: 2, count: 100).write(to: replaced)
    let result = fixture.cleaner.execute(plan, activity: CleanupActivity())
    #expect(result.removedFiles == 0)
    #expect(result.skipped[.changed] == 2)
    #expect(FileManager.default.fileExists(atPath: changed.path))
    #expect(FileManager.default.fileExists(atPath: replaced.path))
}

@Test func cleanupRejectsAncestorReplacedWithSymlink() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let target = try fixture.file("Library/Caches/example/cache.bin")
    let outside = try fixture.file("Documents/cache.bin")
    let plan = try fixture.cleaner.plan(paths: [target], settings: CleanupSettings(), activity: CleanupActivity())
    let directory = target.deletingLastPathComponent()
    try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("moved"))
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside.deletingLastPathComponent())
    let result = fixture.cleaner.execute(plan, activity: CleanupActivity())
    #expect(result.removedFiles == 0)
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test func cleanupSecondActivitySnapshotPreventsRemoval() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let file = try fixture.file("Library/Caches/example/file.bin")
    let plan = try fixture.cleaner.plan(paths: [file], settings: CleanupSettings(), activity: CleanupActivity())
    let result = fixture.cleaner.execute(plan, activity: CleanupActivity(openPaths: [file.path]))
    #expect(result.removedFiles == 0)
    #expect(result.skipped[.inUse] == 1)
}

@Test func cleanupRechecksProtectionAndRejectsExpiredPlans() throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let file = try fixture.file("Library/Caches/example/file.bin")
    let plan = try fixture.cleaner.plan(paths: [file], settings: CleanupSettings(), activity: CleanupActivity())
    let result = fixture.cleaner.execute(plan, activity: CleanupActivity(), additionalProtection: [file.deletingLastPathComponent().path])
    #expect(result.removedFiles == 0)
    #expect(result.skipped[.protected] == 1)
    let expired = try fixture.cleaner.plan(paths: [file], settings: CleanupSettings(), activity: CleanupActivity(), now: Date(timeIntervalSinceNow: -601))
    #expect(expired.files.count == 1)
    let expiredResult = fixture.cleaner.execute(expired, activity: CleanupActivity())
    #expect(expiredResult.removedFiles == 0)
    #expect(expiredResult.skipped[.changed] == 1)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func cancelledCleanupKeepsFilesAndReportsPartialResult() async throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let file = try fixture.file("Library/Caches/example/file.bin")
    let plan = try fixture.cleaner.plan(paths: [file], settings: CleanupSettings(), activity: CleanupActivity())
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return fixture.cleaner.execute(plan, activity: CleanupActivity())
    }
    let result = await task.value
    #expect(result.cancelled)
    #expect(result.removedFiles == 0)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func molePreviewParsesPathsWithSpacesAndRejectsUnsafeFormat() throws {
    let home = URL(fileURLWithPath: "/Users/Test")
    let text = """
    # Mole Cleanup Preview - date
    # Example: /Users/*/Library/Caches/com.example.app
    === User essentials ===
    /Users/Test/Library/Caches/Example App  # 1.2GB, 3 items
    ~/Library/Logs/old.log  # 4KB
    /Users/Test/Library/Caches/Example App  # 1.2GB
    /Users/Test/Library/Caches/../Documents  # 4KB
    /Users/Test/Library/Caches/*  # 4KB
    """
    #expect(Set(try MolePreview.parse(text, home: home).map(\.path)) == ["/Users/Test/Library/Caches/Example App", "/Users/Test/Library/Logs/old.log"])
    #expect(throws: CleanupFailure.self) { try MolePreview.parse("/Users/Test/Library/Caches/data  # 4KB", home: home) }
    #expect(try MolePreview.parse("# Mole Cleanup Preview - date\n", home: home).isEmpty)
}

@Test func molePreviewRequiresSuccessfulFreshOutputAndPreservesFiles() async throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let candidate = try fixture.file("Library/Caches/example/file.bin")
    let script = fixture.home.appendingPathComponent("fake-mole")
    // Pass a fixed fixture path through proper shell quoting, never the real home directory.
    let folder = fixture.home.appendingPathComponent(".config/mole")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let quoted = "'" + folder.appendingPathComponent("clean-list.txt").path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let body = "#!/bin/bash\n[ \"$1\" = clean ] && [ \"$2\" = --dry-run ] || exit 4\nprintf '%s\\n' '# Mole Cleanup Preview - date' '\(candidate.path)  # 100B' > \(quoted)\n"
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let paths = try await MolePreview.discover(executable: script, home: fixture.home)
    #expect(paths.map(\.path) == [candidate.path])
    #expect(FileManager.default.fileExists(atPath: candidate.path))
    try "#!/bin/bash\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    await #expect(throws: CleanupFailure.self) { try await MolePreview.discover(executable: script, home: fixture.home) }
    try "#!/bin/bash\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: folder.appendingPathComponent("clean-list.txt").path)
    await #expect(throws: CleanupFailure.self) { try await MolePreview.discover(executable: script, home: fixture.home) }
}

@Test func cleanupCommandCancelsAndTimesOut() async throws {
    let fixture = try CleanupFixture()
    defer { fixture.remove() }
    let script = fixture.home.appendingPathComponent("slow-command")
    try "#!/bin/bash\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let task = Task { try await CleanupCommand.run(script, arguments: []) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled command completed") }
    catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    await #expect(throws: CleanupFailure.self) { try await CleanupCommand.run(script, arguments: [], timeout: 0.2) }
}
