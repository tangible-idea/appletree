import Foundation

/// Smart filters that only need the metadata already stored in the scan index.
public enum SearchPreset: String, CaseIterable, Sendable {
    case huge, large, stale, recent, oldDownloads, screenshots, duplicates, devCaches, emptyFolders

    public var title: String { L10n.text("preset.\(rawValue)") }

    public var symbol: String {
        switch self {
        case .huge: "externaldrive.fill"
        case .large: "arrow.up.circle"
        case .stale: "clock.arrow.circlepath"
        case .recent: "sparkles"
        case .oldDownloads: "arrow.down.circle"
        case .screenshots: "camera.viewfinder"
        case .duplicates: "square.on.square"
        case .devCaches: "hammer"
        case .emptyFolders: "folder"
        }
    }

    /// Presets whose results are folders rather than files.
    public var matchesFolders: Bool { self == .devCaches || self == .emptyFolders }
}

public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var kinds: Set<FileKind>
    public var preset: SearchPreset?

    public init(text: String = "", kinds: Set<FileKind> = [], preset: SearchPreset? = nil) {
        self.text = text
        self.kinds = kinds
        self.preset = preset
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isEmpty: Bool { trimmedText.isEmpty && kinds.isEmpty && preset == nil }
}

public struct SearchResult: Sendable {
    public let items: [FileNode]
    public let totalCount: Int
    public let totalSize: Int64

    public init(items: [FileNode] = [], totalCount: Int = 0, totalSize: Int64 = 0) {
        self.items = items
        self.totalCount = totalCount
        self.totalSize = totalSize
    }
}

/// Flat, size-ordered index over a scanned tree. Built once off the main thread;
/// every query is a linear scan over pre-normalised names, split across cores.
public final class SearchIndex: Sendable {
    struct Entry: Sendable {
        let node: FileNode
        let key: String
        let kind: FileKind
        let size: Int64
        let modified: Double
        let order: Int32
        let flags: UInt8
    }

    enum Flag {
        static let downloads: UInt8 = 1 << 0
        static let screenshot: UInt8 = 1 << 1
        static let duplicate: UInt8 = 1 << 2
        static let devCache: UInt8 = 1 << 3
        static let empty: UInt8 = 1 << 4
    }

    private let entries: [Entry]
    /// Pre-order index ranges of every folder's subtree, used to scope a search.
    private let ranges: [ObjectIdentifier: Range<Int32>]

    public var count: Int { entries.count }

    public init(root: FileNode) {
        var entries: [Entry] = []
        entries.reserveCapacity(root.fileCount + root.directoryCount)
        var ranges: [ObjectIdentifier: Range<Int32>] = [:]
        var order: Int32 = 0

        func visit(_ node: FileNode, parent: FileNode?, inDownloads: Bool, inCache: Bool, inEmpty: Bool) {
            let start = order
            order += 1
            let key = SearchIndex.normalize(node.name)
            var flags: UInt8 = 0
            var childCache = inCache
            var childEmpty = inEmpty
            if node.isDirectory {
                if parent != nil && !inCache && SearchIndex.isDevCache(key: key, node: node, parent: parent) {
                    flags |= Flag.devCache
                    childCache = true
                }
                if parent != nil && !inEmpty && node.fileCount == 0 {
                    flags |= Flag.empty
                    childEmpty = true
                }
            } else {
                if inDownloads { flags |= Flag.downloads }
                if SearchIndex.isScreenshot(key) { flags |= Flag.screenshot }
            }
            if parent != nil {
                entries.append(Entry(node: node, key: key, kind: node.kind, size: node.size,
                                     modified: node.modified?.timeIntervalSinceReferenceDate ?? .nan,
                                     order: start, flags: flags))
            }
            let childDownloads = inDownloads || (node.isDirectory && key == "downloads")
            for child in node.children {
                visit(child, parent: node, inDownloads: childDownloads, inCache: childCache, inEmpty: childEmpty)
            }
            if node.isDirectory { ranges[ObjectIdentifier(node)] = start..<order }
        }
        visit(root, parent: nil, inDownloads: false, inCache: false, inEmpty: false)

        entries.sort { a, b in
            if a.size != b.size { return a.size > b.size }
            if a.key != b.key { return a.key < b.key }
            return a.order < b.order
        }

        // Same name and size is a cheap first-pass duplicate signal; contents are never read.
        struct DuplicateKey: Hashable { let size: Int64; let key: String }
        var groups: [DuplicateKey: Int] = [:]
        for entry in entries where !entry.node.isDirectory && entry.size >= SearchIndex.duplicateMinimum {
            groups[DuplicateKey(size: entry.size, key: entry.key), default: 0] += 1
        }
        for index in entries.indices where !entries[index].node.isDirectory && entries[index].size >= SearchIndex.duplicateMinimum {
            let entry = entries[index]
            if groups[DuplicateKey(size: entry.size, key: entry.key)] ?? 0 > 1 {
                entries[index] = Entry(node: entry.node, key: entry.key, kind: entry.kind, size: entry.size,
                                       modified: entry.modified, order: entry.order, flags: entry.flags | Flag.duplicate)
            }
        }

        self.entries = entries
        self.ranges = ranges
    }

    public static let duplicateMinimum: Int64 = 1_000_000

    /// Lowercased, NFC-composed name. macOS stores Korean names decomposed,
    /// while typed queries arrive composed.
    public static func normalize(_ name: String) -> String {
        if name.utf8.allSatisfy({ $0 < 0x80 }) { return name.lowercased() }
        return name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func isScreenshot(_ key: String) -> Bool {
        key.hasPrefix("screenshot") || key.hasPrefix("screen shot") || key.hasPrefix("screen recording")
            || key.hasPrefix("스크린샷") || key.hasPrefix("화면 기록") || key.hasPrefix("cleanshot")
    }

    private static let cacheNames: Set<String> = [
        "node_modules", "deriveddata", ".build", ".gradle", "__pycache__", ".next", ".nuxt", ".parcel-cache",
        ".turbo", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".dart_tool", ".expo", ".swiftpm", "ios devicesupport",
        ".cache", ".npm", ".yarn-cache", ".pnpm-store", ".terraform"
    ]

    /// Folders that build tools recreate on demand. Ambiguous names only count
    /// when a sibling or child proves which tool owns them.
    static func isDevCache(key: String, node: FileNode, parent: FileNode?) -> Bool {
        if cacheNames.contains(key) { return true }
        func parentHas(_ names: Set<String>) -> Bool {
            parent?.children.contains { names.contains($0.name.lowercased()) } ?? false
        }
        switch key {
        case "caches": return parent.map { normalize($0.name) == "library" } ?? false
        case "pods": return parentHas(["podfile"])
        case "target": return parentHas(["cargo.toml", "pom.xml"])
        case "build": return parentHas(["build.gradle", "build.gradle.kts", "cmakelists.txt", "package.json", "pubspec.yaml"])
        case "venv", ".venv", "env": return node.children.contains { $0.name == "pyvenv.cfg" }
        default: return false
        }
    }

    public func search(_ query: SearchQuery, in scope: FileNode? = nil, limit: Int = 200, now: Date = Date()) -> SearchResult {
        let range = scope.flatMap { ranges[ObjectIdentifier($0)] }
        let needle = Array(SearchIndex.normalize(query.trimmedText).utf8)
        let kinds = query.kinds
        let preset = query.preset
        let foldersOnly = preset?.matchesFolders == true
        // Folders appear only for a plain name search; kind filters and file presets want files.
        let allowFolders = foldersOnly || (!needle.isEmpty && kinds.isEmpty && preset == nil)
        let reference = now.timeIntervalSinceReferenceDate
        let day = 86_400.0

        @Sendable func matches(_ entry: Entry) -> Bool {
            if let range, !range.contains(entry.order) || entry.order == range.lowerBound { return false }
            let isDirectory = entry.kind == .folder
            if isDirectory ? !allowFolders : foldersOnly { return false }
            if !kinds.isEmpty && !kinds.contains(entry.kind) { return false }
            if let preset {
                switch preset {
                case .huge: if entry.size < 1_000_000_000 { return false }
                case .large: if entry.size < 100_000_000 { return false }
                case .stale: if !(entry.modified < reference - 365 * day) { return false }
                case .recent: if !(entry.modified >= reference - 7 * day) { return false }
                case .oldDownloads:
                    if entry.flags & Flag.downloads == 0 || !(entry.modified < reference - 30 * day) { return false }
                case .screenshots: if entry.flags & Flag.screenshot == 0 { return false }
                case .duplicates: if entry.flags & Flag.duplicate == 0 { return false }
                case .devCaches: if entry.flags & Flag.devCache == 0 { return false }
                case .emptyFolders: if entry.flags & Flag.empty == 0 { return false }
                }
            }
            if !needle.isEmpty && !SearchIndex.contains(entry.key, needle) { return false }
            return true
        }

        final class Partial: @unchecked Sendable {
            var hits: [[Int]]
            var counts: [Int]
            var sizes: [Int64]
            init(_ chunks: Int) {
                hits = Array(repeating: [], count: chunks)
                counts = Array(repeating: 0, count: chunks)
                sizes = Array(repeating: 0, count: chunks)
            }
        }

        let total = entries.count
        let chunks = total < 20_000 ? 1 : ProcessInfo.processInfo.activeProcessorCount * 4
        let chunkSize = (total + chunks - 1) / max(chunks, 1)
        let partial = Partial(chunks)
        let scan: @Sendable (Int) -> Void = { chunk in
            let lower = chunk * chunkSize
            let upper = min(total, lower + chunkSize)
            guard lower < upper else { return }
            var hits: [Int] = []
            var count = 0
            var size: Int64 = 0
            for index in lower..<upper where matches(self.entries[index]) {
                if hits.count < limit { hits.append(index) }
                count += 1
                size += self.entries[index].size
            }
            partial.hits[chunk] = hits
            partial.counts[chunk] = count
            partial.sizes[chunk] = size
        }
        if chunks == 1 { scan(0) } else { DispatchQueue.concurrentPerform(iterations: chunks, execute: scan) }

        // Chunks are contiguous slices of a size-sorted array, so concatenation keeps the order.
        var items: [FileNode] = []
        items.reserveCapacity(limit)
        for hits in partial.hits {
            for index in hits {
                guard items.count < limit else { break }
                items.append(entries[index].node)
            }
        }
        return SearchResult(items: items, totalCount: partial.counts.reduce(0, +), totalSize: partial.sizes.reduce(0, +))
    }

    static func contains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        var haystack = haystack
        return haystack.withUTF8 { bytes in
            guard bytes.count >= needle.count, let base = bytes.baseAddress else { return false }
            return needle.withUnsafeBufferPointer { pattern in
                memmem(base, bytes.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }
}
