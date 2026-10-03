import Foundation

public struct ScanProgress: Sendable {
    public let files: Int
    public let bytes: Int64
    public let targetBytes: Int64?
    public let path: String

    public init(files: Int, bytes: Int64, targetBytes: Int64? = nil, path: String) {
        self.files = files
        self.bytes = bytes
        self.targetBytes = targetBytes
        self.path = path
    }
}

public struct ScanReport: Sendable, Codable {
    public let root: FileNode
    /// Computed on demand: the app searches through `SearchIndex`, so building
    /// this for every scan or cache load would only cost time.
    public var filesBySize: [FileNode] {
        root.allFiles().sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
    }
    public let unreadableCount: Int
    public let unreadablePaths: [String]
    public let skippedLinks: Int
    public let elapsed: TimeInterval
    public let scannedAt: Date
    public let isCached: Bool

    public init(root: FileNode, unreadableCount: Int = 0,
                unreadablePaths: [String] = [], skippedLinks: Int = 0,
                elapsed: TimeInterval = 0, scannedAt: Date = Date(), isCached: Bool = false) {
        self.root = root
        self.unreadableCount = unreadableCount
        self.unreadablePaths = unreadablePaths
        self.skippedLinks = skippedLinks
        self.elapsed = elapsed
        self.scannedAt = scannedAt
        self.isCached = isCached
    }

    enum CodingKeys: String, CodingKey {
        case root, unreadableCount, unreadablePaths, skippedLinks, elapsed, scannedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root = try container.decode(FileNode.self, forKey: .root)
        let unreadableCount = try container.decode(Int.self, forKey: .unreadableCount)
        let unreadablePaths = try container.decode([String].self, forKey: .unreadablePaths)
        let skippedLinks = try container.decode(Int.self, forKey: .skippedLinks)
        let elapsed = try container.decode(TimeInterval.self, forKey: .elapsed)
        let scannedAt = try container.decodeIfPresent(Date.self, forKey: .scannedAt) ?? Date()
        self.init(root: root, unreadableCount: unreadableCount,
                  unreadablePaths: unreadablePaths, skippedLinks: skippedLinks,
                  elapsed: elapsed, scannedAt: scannedAt, isCached: true)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(unreadableCount, forKey: .unreadableCount)
        try container.encode(unreadablePaths, forKey: .unreadablePaths)
        try container.encode(skippedLinks, forKey: .skippedLinks)
        try container.encode(elapsed, forKey: .elapsed)
        try container.encode(scannedAt, forKey: .scannedAt)
    }
}

public enum ScanFailure: LocalizedError {
    case notDirectory
    public var errorDescription: String? { L10n.text("error.notDirectory") }
}

/// Reads metadata only. Symbolic links are never followed and file contents are never read.
public enum DiskScanner {
    public static func scan(_ url: URL, targetBytes: Int64? = nil, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanReport {
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
                progress(ScanProgress(files: files, bytes: bytes, targetBytes: targetBytes, path: current.path))
                lastUpdate = Date()
            }
            return FileNode(url: current, isDirectory: false, size: size, modified: values.contentModificationDate)
        }

        let root = try visit(url.standardizedFileURL.resolvingSymlinksInPath(), values: rootValues, isRoot: true)
        try Task.checkCancellation()
        progress(ScanProgress(files: files, bytes: bytes, targetBytes: targetBytes, path: url.path))
        return ScanReport(root: root, unreadableCount: unreadableCount,
                          unreadablePaths: unreadablePaths, skippedLinks: skippedLinks,
                          elapsed: Date().timeIntervalSince(start), scannedAt: Date(), isCached: false)
    }
}
