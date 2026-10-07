import Foundation
import Darwin

public struct CleanupFailure: LocalizedError, Sendable {
    public let key: String
    public init(_ key: String) { self.key = key }
    public var errorDescription: String? { L10n.text(key) }
}

public enum MolePreview {
    public static func locate() -> URL? {
        let paths = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", "/usr/local/bin/mole",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mo").path]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func parse(_ text: String, home: URL) throws -> [URL] {
        guard text.hasPrefix("# Mole Cleanup Preview"), text.utf8.count <= 16_000_000 else {
            throw CleanupFailure("cleanup.error.previewFormat")
        }
        var paths: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("/") || line.hasPrefix("~/"),
                  let delimiter = line.range(of: "  # ") else { continue }
            let raw = String(line[..<delimiter.lowerBound])
            // The CLI's human-readable list cannot represent these paths unambiguously.
            guard !raw.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }),
                  !raw.contains("  # "), !raw.contains("*"), !raw.contains("?"),
                  !raw.contains("["), !raw.contains("|"), !raw.split(separator: "/").contains("..") else { continue }
            let expanded = raw.hasPrefix("~/") ? home.path + "/" + raw.dropFirst(2) : raw
            paths.insert(URL(fileURLWithPath: expanded).path)
        }
        return paths.sorted().map { URL(fileURLWithPath: $0) }
    }

    public static func discover(executable: URL, home: URL,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [URL] {
        // Lock only AppleTree's preview sessions; never alter Mole's whitelist or authentication.
        let folder = home.appendingPathComponent(".config/mole")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard folder.standardizedFileURL.resolvingSymlinksInPath().path == folder.standardizedFileURL.path else {
            throw CleanupFailure("cleanup.error.previewFormat")
        }
        let descriptor = open(folder.appendingPathComponent("appletree-preview.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CleanupFailure("cleanup.error.previewRead") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CleanupFailure("cleanup.error.busy") }
        defer { flock(descriptor, LOCK_UN) }
        let started = Date()
        let output = try await CleanupCommand.run(executable, arguments: ["clean", "--dry-run"], timeout: 180, progress: progress)
        guard output.status == 0 else { throw CleanupFailure("cleanup.error.moleFailed") }
        let preview = folder.appendingPathComponent("clean-list.txt")
        let fd = open(preview.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CleanupFailure("cleanup.error.previewRead") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_size <= 16_000_000,
              Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000 >= started.timeIntervalSince1970 else {
            throw CleanupFailure("cleanup.error.previewRead")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            throw CleanupFailure("cleanup.error.previewRead")
        }
        return try parse(text, home: home)
    }

    public static func protectedPatterns(home: URL) throws -> [String] {
        let url = home.appendingPathComponent(".config/mole/whitelist")
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return [] }
            throw CleanupFailure("cleanup.error.previewRead")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_size < 1_000_000 else {
            throw CleanupFailure("cleanup.error.previewRead")
        }
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            let expanded = value.replacingOccurrences(of: "${HOME}", with: home.path)
                .replacingOccurrences(of: "$HOME", with: home.path)
            return expanded.hasPrefix("~/") ? home.path + "/" + expanded.dropFirst(2) : expanded
        }
    }
}

/// Executes fixed argument arrays without a shell. Output is file-backed to avoid pipe deadlocks.
public enum CleanupCommand {
    public struct Output: Sendable {
        public let status: Int32
        public let text: String
    }

    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 20,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Output {
        try Task.checkCancellation()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-cleanup-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CleanupFailure("cleanup.error.previewRead")
        }
        defer { try? FileManager.default.removeItem(at: log) }
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = writer
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        try process.run()
        let started = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date().timeIntervalSince(started) < timeout else { throw CleanupFailure("cleanup.error.timeout") }
                if let reader = try? FileHandle(forReadingFrom: log) {
                    let end = (try? reader.seekToEnd()) ?? 0
                    try? reader.seek(toOffset: end > 4096 ? end - 4096 : 0)
                    let data = (try? reader.readToEnd()) ?? Data()
                    try? reader.close()
                    let line = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                    progress(line)
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            stop(process)
            throw error
        }
        let size = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 32_000_000 else { throw CleanupFailure("cleanup.error.previewFormat") }
        return Output(status: process.terminationStatus, text: try String(contentsOf: log, encoding: .utf8))
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        // Freeze the parent before discovering descendants, then stop the whole preview tree.
        let parent = process.processIdentifier
        kill(parent, SIGSTOP)
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        var pairs: [(Int32, Int32)] = []
        if (try? ps.run()) != nil {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            pairs = text.split(separator: "\n").compactMap {
                let values = $0.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                return values.count == 2 ? (values[0], values[1]) : nil
            }
        }
        var descendants: Set<Int32> = [parent]
        var changed = true
        while changed {
            changed = false
            for (pid, ppid) in pairs where descendants.contains(ppid) {
                if descendants.insert(pid).inserted { changed = true }
            }
        }
        for pid in descendants where pid != parent { kill(pid, SIGKILL) }
        kill(parent, SIGKILL)
        // waitUntilExit could block forever on a busy cooperative thread; SIGKILL can't be ignored,
        // so a short bounded wait for Foundation to notice the exit is enough.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
    }
}
