import Foundation
import CryptoKit
import AppleTreeCore

@MainActor
final class ScanIndexCache {
    static let shared = ScanIndexCache()

    private var memoryCache: ScanReportMemoryCache
    var memoryNodeCount: Int { memoryCache.nodeCount }
    var memoryReportCount: Int { memoryCache.count }
    private var loading: [String: Task<ScanReport?, Never>] = [:]
    private let cacheDirectory: URL
    private let manifestURL: URL
    private var manifest: [String: ManifestEntry] = [:]

    struct ManifestEntry: Codable {
        let path: String
        let fileName: String
        let size: Int64
        let scannedAt: Date
    }

    init(directory: URL? = nil, nodeLimit: Int = 100_000, reportLimit: Int = 2) {
        self.memoryCache = ScanReportMemoryCache(nodeLimit: nodeLimit, reportLimit: reportLimit)
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AppleTree", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree", isDirectory: true)
        self.cacheDirectory = base.appendingPathComponent("Scans", isDirectory: true)
        self.manifestURL = base.appendingPathComponent("manifest.plist")

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadManifest()
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func key(for path: String) -> String {
        let clean = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        return clean
    }

    private func deterministicFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()
        let safeName = key.replacingOccurrences(of: "/", with: "_").prefix(30)
        return "\(safeName)_\(hashHex.prefix(16)).\(Self.fileExtension)"
    }

    private func fileURL(for key: String) -> URL {
        let name = manifest[key]?.fileName ?? deterministicFileName(for: key)
        return cacheDirectory.appendingPathComponent(name)
    }

    private static let fileExtension = "atix"

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? PropertyListDecoder().decode([String: ManifestEntry].self, from: data) else {
            return
        }
        // Entries from earlier builds still point at property lists; `get` converts them on first load.
        manifest = decoded
    }

    private func saveManifest() {
        let current = manifest
        let dest = manifestURL
        Task.detached(priority: .utility) {
            guard let data = try? PropertyListEncoder().encode(current) else { return }
            try? data.write(to: dest, options: .atomic)
        }
    }

    /// Size recorded for an exact cached root, without loading the tree.
    func cachedSize(for url: URL) -> Int64? {
        manifest[key(for: canonicalPath(for: url))]?.size
    }

    /// Loads a cached tree, decoding off the main thread. Concurrent requests share one load.
    func get(for url: URL) async -> ScanReport? {
        let pathKey = key(for: canonicalPath(for: url))
        if let memory = memoryCache.value(forKey: pathKey) { return memory }
        if let pending = loading[pathKey] { return await pending.value }
        guard let entry = manifest[pathKey] else { return nil }
        let file = cacheDirectory.appendingPathComponent(entry.fileName)
        let isLegacy = !entry.fileName.hasSuffix(".\(Self.fileExtension)")
        let converted = cacheDirectory.appendingPathComponent(deterministicFileName(for: pathKey))
        let task = Task.detached(priority: .userInitiated) { () -> ScanReport? in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            guard isLegacy else { return try? ScanArchive.decode(data) }
            // Earlier builds wrote keyed property lists: slow to read, but a whole disk's
            // index is too costly to throw away. Convert once, and remove the original
            // only after the compact copy is safely on disk.
            guard let report = try? PropertyListDecoder().decode(ScanReport.self, from: data) else { return nil }
            if (try? ScanArchive.encode(report).write(to: converted, options: .atomic)) != nil {
                try? FileManager.default.removeItem(at: file)
            }
            return report
        }
        loading[pathKey] = task
        let report = await task.value
        loading[pathKey] = nil
        if let report {
            memoryCache.insert(report, forKey: pathKey)
            if isLegacy && FileManager.default.fileExists(atPath: converted.path) {
                manifest[pathKey] = ManifestEntry(path: entry.path, fileName: converted.lastPathComponent,
                                                  size: entry.size, scannedAt: entry.scannedAt)
                saveManifest()
            }
        }
        return report
    }

    /// Finds a node within any previously scanned parent tree.
    func findNodeInCachedTrees(for url: URL, activeReport: ScanReport? = nil) async -> (report: ScanReport, node: FileNode)? {
        let targetPath = canonicalPath(for: url)
        // The active tree can exceed the cache budget. Reuse it without retaining a second copy.
        if let activeReport, activeReport.root.url.path == targetPath {
            _ = memoryCache.value(forKey: targetPath)
            return (activeReport, activeReport.root)
        }

        if let direct = await get(for: url) {
            return (direct, direct.root)
        }
        // An exact cached scan can be newer than the active ancestor's snapshot.
        if let activeReport, let node = activeReport.root.findNode(path: targetPath) {
            _ = memoryCache.value(forKey: activeReport.root.url.path)
            return (activeReport, node)
        }

        func contains(_ rootPath: String) -> Bool {
            targetPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }

        for report in memoryCache.reports where contains(canonicalPath(for: report.root.url)) {
            if let found = report.root.findNode(path: targetPath) {
                _ = memoryCache.value(forKey: canonicalPath(for: report.root.url))
                return (report, found)
            }
        }

        // Prefer the closest cached ancestor: it is the smallest tree to load.
        for entry in manifest.values.filter({ contains($0.path) }).sorted(by: { $0.path.count > $1.path.count }) {
            if let report = await get(for: URL(fileURLWithPath: entry.path)),
               let found = report.root.findNode(path: targetPath) {
                return (report, found)
            }
        }
        return nil
    }

    func set(_ report: ScanReport, for url: URL) {
        let pathKey = key(for: canonicalPath(for: url))
        memoryCache.insert(report, forKey: pathKey)

        let fileName = deterministicFileName(for: pathKey)
        let entry = ManifestEntry(path: pathKey, fileName: fileName,
                                  size: report.root.size, scannedAt: report.scannedAt)
        manifest[pathKey] = entry
        saveManifest()

        let file = cacheDirectory.appendingPathComponent(fileName)
        Task.detached(priority: .utility) {
            try? ScanArchive.encode(report).write(to: file, options: .atomic)
        }
    }

    func loadMostRecent() async -> ScanReport? {
        let sorted = manifest.values.sorted(by: { $0.scannedAt > $1.scannedAt })
        for entry in sorted {
            if let report = await get(for: URL(fileURLWithPath: entry.path)) {
                return report
            }
        }
        return nil
    }

    func remove(for url: URL) {
        let pathKey = key(for: canonicalPath(for: url))
        let file = fileURL(for: pathKey)
        memoryCache.removeValue(forKey: pathKey)
        manifest.removeValue(forKey: pathKey)
        saveManifest()
        try? FileManager.default.removeItem(at: file)
    }

    func clearAll() {
        memoryCache.removeAll()
        manifest.removeAll()
        saveManifest()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
