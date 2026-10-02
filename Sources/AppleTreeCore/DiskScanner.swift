import Foundation

public struct ScanProgress: Sendable {
    public let files: Int
    public let bytes: Int64
    public let path: String
}

public struct ScanReport: Sendable {
    public let root: FileNode
    public let filesBySize: [FileNode]
    public let unreadableCount: Int
    public let unreadablePaths: [String]
    public let skippedLinks: Int
    public let elapsed: TimeInterval
}

public enum ScanFailure: LocalizedError {
    case notDirectory
    public var errorDescription: String? { L10n.text("error.notDirectory") }
}

/// Reads metadata only. Symbolic links are never followed and file contents are never read.
public enum DiskScanner {
    public static func scan(_ url: URL, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanReport {
        let start = Date()
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                       .fileSizeKey, .contentModificationDateKey]
        let rootValues = try url.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ScanFailure.notDirectory }
        var files = 0
        var bytes: Int64 = 0
        var unreadableCount = 0
        var unreadablePaths: [String] = []
        var skippedLinks = 0
        var lastUpdate = Date.distantPast

        func recordIssue(_ path: String) {
            unreadableCount += 1
            if unreadablePaths.count < 20 { unreadablePaths.append(path) }
        }

        func visit(_ current: URL, values: URLResourceValues, isRoot: Bool = false) throws -> FileNode {
            try Task.checkCancellation()
            if values.isDirectory == true {
                var children: [FileNode] = []
                let urls: [URL]
                do {
                    urls = try manager.contentsOfDirectory(at: current, includingPropertiesForKeys: Array(keys))
                } catch {
                    if isRoot { throw error }
                    recordIssue(current.path)
                    return FileNode(url: current, isDirectory: true, size: 0)
                }
                for entry in urls {
                    try Task.checkCancellation()
                    // Foundation may enumerate /var as /private/var. Keep every node
                    // under the same URL spelling so scoped search and breadcrumbs agree.
                    let child = current.appendingPathComponent(entry.lastPathComponent)
                    do {
                        let metadata = try entry.resourceValues(forKeys: keys)
                        if metadata.isSymbolicLink == true { skippedLinks += 1; continue }
                        guard metadata.isDirectory == true || metadata.isRegularFile == true else { continue }
                        children.append(try visit(child, values: metadata))
                    } catch is CancellationError { throw CancellationError() }
                    catch { recordIssue(child.path) }
                }
                children.sort { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
                return FileNode(url: current, isDirectory: true, size: children.reduce(0) { $0 + $1.size },
                                children: children, modified: values.contentModificationDate)
            }
            let size = Int64(values.fileSize ?? 0)
            files += 1
            bytes += size
            if Date().timeIntervalSince(lastUpdate) >= 0.12 {
                progress(ScanProgress(files: files, bytes: bytes, path: current.path))
                lastUpdate = Date()
            }
            return FileNode(url: current, isDirectory: false, size: size, modified: values.contentModificationDate)
        }

        let root = try visit(url.standardizedFileURL.resolvingSymlinksInPath(), values: rootValues, isRoot: true)
        try Task.checkCancellation()
        let allFiles = root.allFiles().sorted { $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size }
        progress(ScanProgress(files: files, bytes: bytes, path: url.path))
        return ScanReport(root: root, filesBySize: allFiles, unreadableCount: unreadableCount,
                          unreadablePaths: unreadablePaths, skippedLinks: skippedLinks,
                          elapsed: Date().timeIntervalSince(start))
    }
}
