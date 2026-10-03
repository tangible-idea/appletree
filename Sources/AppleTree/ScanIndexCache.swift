import Foundation
import CryptoKit
import AppleTreeCore

@MainActor
final class ScanIndexCache {
    static let shared = ScanIndexCache()

    private var memoryCache: [String: ScanReport] = [:]
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

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
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
        // Earlier builds stored keyed property lists that took a minute to load for a
        // home folder. They cannot be read cheaply, so drop them and rescan instead.
        let legacy = decoded.values.filter { !$0.fileName.hasSuffix(".\(Self.fileExtension)") }
        for entry in legacy {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(entry.fileName))
        }
        manifest = decoded.filter { $0.value.fileName.hasSuffix(".\(Self.fileExtension)") }
        if !legacy.isEmpty { saveManifest() }
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
        if let memory = memoryCache[pathKey] { return memory }
        if let pending = loading[pathKey] { return await pending.value }
        guard manifest[pathKey] != nil else { return nil }
        let file = fileURL(for: pathKey)
        let task = Task.detached(priority: .userInitiated) { () -> ScanReport? in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            return try? ScanArchive.decode(data)
        }
        loading[pathKey] = task
        let report = await task.value
        loading[pathKey] = nil
        if let report { memoryCache[pathKey] = report }
        return report
    }

    /// Finds a node within any previously scanned parent tree.
    func findNodeInCachedTrees(for url: URL) async -> (report: ScanReport, node: FileNode)? {
        let targetPath = canonicalPath(for: url)

        if let direct = await get(for: url) {
            return (direct, direct.root)
        }

        func contains(_ rootPath: String) -> Bool {
            targetPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }

        for (_, report) in memoryCache where contains(canonicalPath(for: report.root.url)) {
            if let found = report.root.findNode(path: targetPath) { return (report, found) }
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
        memoryCache[pathKey] = report

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
        memoryCache.removeValue(forKey: pathKey)
        manifest.removeValue(forKey: pathKey)
        saveManifest()
        let file = fileURL(for: pathKey)
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
