import Foundation
import Darwin

public enum CleanupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case appCaches, toolCaches, oldLogs
    public var id: String { rawValue }
    public var title: String { L10n.text("cleanup.category.\(rawValue)") }
    public var detail: String { L10n.text("cleanup.category.\(rawValue).detail") }
}

public struct CleanupSettings: Codable, Equatable, Sendable {
    public var categories: Set<CleanupCategory> = [.appCaches, .oldLogs]
    public var protectedPaths: [String] = []
    public var cacheAgeDays = 7
    public var logAgeDays = 30
    public init() {}
}

public enum CleanupSkip: String, Codable, Sendable, CaseIterable {
    case protected, recent, inUse, unreadable, changed, unsupported, limit
    public var title: String { L10n.text("cleanup.skip.\(rawValue)") }
}

public struct CleanupActivity: Sendable {
    public var openPaths: Set<String>
    public var appIdentifiers: Set<String>
    public var appNames: Set<String>
    public var busyTools: Set<String>
    public init(openPaths: Set<String> = [], appIdentifiers: Set<String> = [],
                appNames: Set<String> = [], busyTools: Set<String> = []) {
        self.openPaths = openPaths
        self.appIdentifiers = appIdentifiers
        self.appNames = appNames
        self.busyTools = busyTools
    }
}

public struct CleanupFile: Sendable {
    public let url: URL
    public let category: CleanupCategory
    public let size: Int64
    let device: dev_t
    let inode: ino_t
    let modified: timespec
    let changed: timespec
}

public struct CleanupPlan: Sendable {
    public let files: [CleanupFile]
    public let measured: [CleanupCategory: Int64]
    public let skipped: [CleanupSkip: Int]
    public let createdAt: Date
    let settings: CleanupSettings
    let moleProtection: [String]
    public var eligibleBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct CleanupResult: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let before: [CleanupCategory: Int64]
    public let removed: [CleanupCategory: Int64]
    public let removedFiles: Int
    public let skipped: [CleanupSkip: Int]
    public let freeBefore: Int64?
    public let freeAfter: Int64?
    public let cancelled: Bool
    public var removedBytes: Int64 { removed.values.reduce(0, +) }
    public var freeDelta: Int64? {
        guard let freeBefore, let freeAfter else { return nil }
        return freeAfter - freeBefore
    }
    public var skippedCount: Int { skipped.values.reduce(0, +) }
}

/// Mole supplies candidates; this policy restricts them to selected, user-owned cache/log files.
/// Deletion uses directory descriptors so a replaced ancestor cannot redirect an unlink.
public struct SmartCleanup: Sendable {
    private static let toolRoots = [".npm/_cacache", ".cache/pip", "Library/Caches/pip",
                                    "Library/Caches/Homebrew/downloads", "Library/Caches/Yarn", "Library/Caches/go-build"]
    public let home: URL
    private let homeAlias: String
    private let owner: uid_t
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeAlias = home.path
        // Foundation rewrites /private/var back to the /var symlink on macOS.
        // Keep the POSIX spelling for descriptor traversal with O_NOFOLLOW.
        if let path = realpath(home.path, nil) {
            self.home = URL(fileURLWithPath: String(cString: path))
            free(path)
        } else { self.home = home }
        self.owner = getuid()
    }

    public func plan(paths: [URL], settings: CleanupSettings, activity: CleanupActivity,
                     moleProtection: [String] = [], now: Date = Date(),
                     progress: (URL) -> Void = { _ in }) throws -> CleanupPlan {
        var files: [CleanupFile] = []
        var measured: [CleanupCategory: Int64] = [:]
        var skipped: [CleanupSkip: Int] = [:]
        var visited: Set<String> = []
        var count = 0
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var reachedLimit = false

        func visit(_ url: URL) throws {
            try Task.checkCancellation()
            let url = canonical(url)
            guard visited.insert(url.path).inserted else { return }
            guard !url.pathComponents.contains("..") else { skipped[.protected, default: 0] += 1; return }
            count += 1
            guard count <= 100_000 else {
                if !reachedLimit { skipped[.limit, default: 0] += 1; reachedLimit = true }
                return
            }
            guard let category = category(for: url) else { return }
            if !settings.categories.contains(category) {
                let relative = String(url.path.dropFirst(home.path.count + 1))
                // Traverse disabled app-cache roots only to reach explicitly enabled tool caches.
                guard settings.categories.contains(.toolCaches),
                      Self.toolRoots.contains(where: { $0.hasPrefix(relative + "/") }) else { return }
            }
            if isProtected(url, settings: settings, patterns: moleProtection) {
                skipped[.protected, default: 0] += 1; return
            }
            guard let metadata = metadata(url) else { skipped[.unreadable, default: 0] += 1; return }
            let kind = metadata.st_mode & S_IFMT
            guard metadata.st_uid == owner else { skipped[.protected, default: 0] += 1; return }
            if kind == S_IFDIR {
                let relative = String(url.path.dropFirst(home.path.count + 1))
                let isSharedRoot = ["Library/Caches", "Library/Logs", "Library/DiagnosticReports"].contains(relative)
                guard isSharedRoot || !isBusy(url, activity: activity) else { skipped[.inUse, default: 0] += 1; return }
                progress(url)
                do {
                    for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) {
                        if reachedLimit { break }
                        try visit(url.appendingPathComponent(child.lastPathComponent))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { skipped[.unreadable, default: 0] += 1 }
                return
            }
            guard settings.categories.contains(category) else { return }
            guard kind == S_IFREG, metadata.st_nlink == 1 else {
                skipped[.protected, default: 0] += 1; return
            }
            let size = Int64(metadata.st_size)
            measured[category, default: 0] += size
            if category == .oldLogs && !["log", "crash", "ips", "diag"].contains(url.pathExtension.lowercased()) {
                skipped[.unsupported, default: 0] += 1; return
            }
            if isBusy(url, activity: activity) { skipped[.inUse, default: 0] += 1; return }
            let age = max(1, category == .oldLogs ? settings.logAgeDays : settings.cacheAgeDays)
            guard Double(metadata.st_mtimespec.tv_sec) <= now.timeIntervalSince1970 - Double(age) * 86_400 else {
                skipped[.recent, default: 0] += 1; return
            }
            files.append(CleanupFile(url: url, category: category, size: size, device: metadata.st_dev,
                                     inode: metadata.st_ino, modified: metadata.st_mtimespec, changed: metadata.st_ctimespec))
        }

        // Ancestors first; visited paths deduplicate Mole's overlapping cleanup sections.
        for path in paths.sorted(by: { $0.path.count < $1.path.count }) {
            if reachedLimit { break }
            try visit(path)
        }
        return CleanupPlan(files: files.sorted { $0.size > $1.size }, measured: measured, skipped: skipped,
                           createdAt: now, settings: settings, moleProtection: moleProtection)
    }

    public func execute(_ plan: CleanupPlan, activity: CleanupActivity, additionalProtection: [String] = [],
                        progress: @Sendable (Int, Int) -> Void = { _, _ in },
                        current: (URL) -> Void = { _ in }) -> CleanupResult {
        let freeBefore = freeSpace()
        var removed: [CleanupCategory: Int64] = [:]
        var removedFiles = 0
        var skipped = plan.skipped
        var cancelled = Task.isCancelled
        for (index, file) in plan.files.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            progress(index, plan.files.count)
            current(file.url)
            if Date().timeIntervalSince(plan.createdAt) > 600 {
                skipped[.changed, default: 0] += plan.files.count - index; break
            }
            guard category(for: file.url) == file.category, plan.settings.categories.contains(file.category),
                  !isProtected(file.url, settings: plan.settings, patterns: plan.moleProtection + additionalProtection) else {
                skipped[.protected, default: 0] += 1; continue
            }
            guard !isBusy(file.url, activity: activity) else { skipped[.inUse, default: 0] += 1; continue }
            guard let parent = openParent(file.url) else { skipped[.changed, default: 0] += 1; continue }
            defer { close(parent) }
            var current = stat()
            guard fstatat(parent, file.url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & S_IFMT == S_IFREG, current.st_uid == owner, current.st_nlink == 1,
                  current.st_dev == file.device, current.st_ino == file.inode, current.st_size == file.size,
                  same(current.st_mtimespec, file.modified), same(current.st_ctimespec, file.changed),
                  parentStillAtPath(parent, file.url.deletingLastPathComponent()) else {
                skipped[.changed, default: 0] += 1; continue
            }
            if unlinkat(parent, file.url.lastPathComponent, 0) == 0 {
                removed[file.category, default: 0] += file.size
                removedFiles += 1
            } else { skipped[.unreadable, default: 0] += 1 }
        }
        progress(plan.files.count, plan.files.count)
        return CleanupResult(id: UUID(), date: Date(), before: plan.measured, removed: removed,
                             removedFiles: removedFiles, skipped: skipped, freeBefore: freeBefore,
                             freeAfter: freeSpace(), cancelled: cancelled)
    }

    private func category(for url: URL) -> CleanupCategory? {
        let prefix = home.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let relative = String(url.path.dropFirst(prefix.count))
        func under(_ root: String) -> Bool { relative == root || relative.hasPrefix(root + "/") }
        if Self.toolRoots.contains(where: under) { return .toolCaches }
        if under("Library/Caches") { return .appCaches }
        if under("Library/Logs") || under("Library/DiagnosticReports") { return .oldLogs }
        return nil
    }

    private func isProtected(_ url: URL, settings: CleanupSettings, patterns: [String]) -> Bool {
        let parts = String(url.path.dropFirst(home.path.count)).split(separator: "/").map { $0.lowercased() }
        if parts.contains(where: { ["appletree", "mole", ".git", ".svn", "node_modules", "deriveddata",
                                   ".build", "target", "models", "model", "offline", "local storage",
                                   "indexeddb", "service worker", "databases", "huggingface", "transformers",
                                   "torch", "ollama", "mlx", "com.apple.e5rt.e5bundlecache"].contains($0) }) { return true }
        if [.certificate, .database, .model, .virtualMachine].contains(FileKind.classify(url)) { return true }
        if settings.protectedPaths.contains(where: {
            let path = canonical(URL(fileURLWithPath: $0)).path
            return url.path == path || url.path.hasPrefix(path + "/")
        }) { return true }
        // Match each ancestor too: protecting a folder protects every file below it.
        var path = url.path
        while path.hasPrefix(home.path + "/") {
            if patterns.contains(where: {
                let pattern = $0.hasPrefix(homeAlias + "/") ? home.path + $0.dropFirst(homeAlias.count) : $0
                return fnmatch(pattern, path, 0) == 0
            }) { return true }
            path = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return false
    }

    private func isBusy(_ url: URL, activity: CleanupActivity) -> Bool {
        let path = url.path
        if activity.openPaths.contains(path) || activity.openPaths.contains(where: { $0.hasPrefix(path + "/") }) { return true }
        let normalized = String(path.dropFirst(home.path.count)).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." }
        if activity.appIdentifiers.contains(where: { normalized.contains($0.lowercased()) }) { return true }
        if activity.appNames.contains(where: {
            let name = $0.lowercased().filter { $0.isLetter || $0.isNumber }
            return name.count >= 4 && normalized.replacingOccurrences(of: ".", with: "").contains(name)
        }) { return true }
        return activity.busyTools.contains(where: { tool in
            let lower = path.lowercased()
            switch tool {
            case "node": return lower.contains("npm") || lower.contains("yarn")
            case "python": return lower.contains("pip")
            case "brew": return lower.contains("homebrew")
            case "go": return lower.contains("go-build")
            default: return false
            }
        })
    }

    private func metadata(_ url: URL) -> stat? {
        guard let parent = openParent(url) else { return nil }
        defer { close(parent) }
        var value = stat()
        guard fstatat(parent, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return value
    }

    private func openParent(_ url: URL) -> Int32? {
        let components = url.deletingLastPathComponent().pathComponents.dropFirst()
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    private func parentStillAtPath(_ descriptor: Int32, _ expected: URL) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return false }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) == expected.path
    }

    private func same(_ left: timespec, _ right: timespec) -> Bool {
        left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec
    }

    private func canonical(_ url: URL) -> URL {
        if url.path.hasPrefix(homeAlias + "/") {
            return URL(fileURLWithPath: home.path + url.path.dropFirst(homeAlias.count))
        }
        return url
    }

    private func freeSpace() -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: home.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
