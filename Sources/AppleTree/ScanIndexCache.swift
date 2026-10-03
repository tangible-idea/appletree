import Foundation
import CryptoKit
import AppleTreeCore

@MainActor
final class ScanIndexCache {
    static let shared = ScanIndexCache()

    private var memoryCache: [String: ScanReport] = [:]
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
        return "\(safeName)_\(hashHex.prefix(16)).plist"
    }

    private func fileURL(for key: String) -> URL {
        let name = manifest[key]?.fileName ?? deterministicFileName(for: key)
        return cacheDirectory.appendingPathComponent(name)
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? PropertyListDecoder().decode([String: ManifestEntry].self, from: data) else {
            return
        }
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

    func get(for url: URL) -> ScanReport? {
        let pathKey = key(for: canonicalPath(for: url))
        if let memory = memoryCache[pathKey] {
            return memory
        }
        let file = fileURL(for: pathKey)
        if FileManager.default.fileExists(atPath: file.path),
           let data = try? Data(contentsOf: file),
           let report = try? PropertyListDecoder().decode(ScanReport.self, from: data) {
            memoryCache[pathKey] = report
            return report
        }
        return nil
    }

    /// Finds a node within any previously scanned parent tree
    func findNodeInCachedTrees(for url: URL) -> (report: ScanReport, node: FileNode)? {
        let targetPath = canonicalPath(for: url)

        // First check exact match
        if let direct = get(for: url) {
            return (direct, direct.root)
        }

        // Then check if any cached tree contains this path
        for (_, report) in memoryCache {
            let rootPath = canonicalPath(for: report.root.url)
            if targetPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
                if let found = report.root.findNode(path: targetPath) {
                    return (report, found)
                }
            }
        }

        // Also check manifest entries on disk
        for entry in manifest.values {
            let rootPath = entry.path
            if targetPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
                let rootURL = URL(fileURLWithPath: rootPath)
                if let report = get(for: rootURL), let found = report.root.findNode(path: targetPath) {
                    return (report, found)
                }
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
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let data = try? encoder.encode(report) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    func loadMostRecent() -> ScanReport? {
        let sorted = manifest.values.sorted(by: { $0.scannedAt > $1.scannedAt })
        for entry in sorted {
            let url = URL(fileURLWithPath: entry.path)
            if let report = get(for: url) {
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
