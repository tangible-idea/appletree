import Foundation
import AppleTreeCore

/// Writes a zip of selected files and folders with the system's libarchive (`bsdtar`),
/// which flags UTF-8 names so Korean file names survive on other systems.
enum ArchiveExporter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Paths inside the archive are relative to `base`; folders are added with their contents.
    /// `progress` receives 0…1 based on entries written so far.
    static func zip(_ nodes: [FileNode], base: URL, to destination: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let relative = nodes.compactMap { node -> String? in
            node.url.path.hasPrefix(basePath) ? String(node.url.path.dropFirst(basePath.count)) : nil
        }
        guard !relative.isEmpty else { throw Failure(message: L10n.text("export.empty")) }
        let expected = max(1, nodes.reduce(0) { $0 + ($1.isDirectory ? $1.fileCount + 1 : 1) })

        // Write beside the destination under a hidden name, excluded from the archive in case
        // the destination lies inside a folder being archived; rename only once it succeeded.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".appletree-\(UUID().uuidString).zip.partial")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-c", "-v", "--format", "zip", "-f", partial.path,
                             "--exclude", partial.lastPathComponent, "-C", base.path, "--null", "-T", "-"]
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let log = ExportLog()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let written = log.append(data)
            progress(min(0.99, Double(written) / Double(expected)))
        }

        // Registered before launch so a very quick exit cannot be missed.
        let finished = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        try process.run()

        // bsdtar reads the list while it archives; feeding it from a plain thread keeps
        // a long list from tying up a Swift concurrency thread while the pipe is full.
        let list = relative.reduce(into: Data()) { data, path in
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
        let writer = input.fileHandleForWriting
        Thread.detachNewThread {
            writer.write(list)
            try? writer.close()
        }

        await withTaskCancellationHandler {
            for await _ in finished {}
        } onCancel: {
            process.terminate()
        }
        errors.fileHandleForReading.readabilityHandler = nil

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: partial)
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure(message: log.lastProblem ?? "bsdtar exited with status \(process.terminationStatus)")
        }
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
    }
}

/// Collects bsdtar's stderr: one "a path" line per entry written, anything else is a problem.
private final class ExportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var written = 0
    private var problem: String?

    var lastProblem: String? {
        lock.lock()
        defer { lock.unlock() }
        return problem
    }

    func append(_ data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.hasPrefix("a ") { written += 1 } else if !line.isEmpty { problem = line }
        }
        return written
    }
}
