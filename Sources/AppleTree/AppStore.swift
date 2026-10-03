import AppKit
import SwiftUI
import AppleTreeCore

enum BrowserMode: String, CaseIterable {
    case folders, largest

    var title: String { L10n.text("browser.\(rawValue)") }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var root = DemoData.make()
    @Published var navigation: [FileNode] = []
    @Published var selected: FileNode?
    @Published var isDemo = true
    @Published var isScanning = false
    @Published var progress: ScanProgress?
    @Published var report: ScanReport?
    @Published var query = "" {
        didSet {
            if !query.isEmpty && scopedFiles.isEmpty && current.id != root.id {
                updateScopedFiles()
            }
        }
    }
    @Published var mode: BrowserMode = .folders {
        didSet {
            if mode == .largest {
                updateScopedFiles()
            }
        }
    }
    @Published var showMap = true
    @Published var errorMessage: String?
    @Published var trashCandidate: FileNode?
    @Published var notice: String?
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published var showFDAPrompt = false
    @Published private var scopedFiles: [FileNode] = []
    private var allFiles: [FileNode] = []
    private var scanTask: Task<ScanReport, Error>?
    private var scanID = UUID()
    private var observationTask: Task<Void, Never>?
    private var pendingScanURL: URL?
    private var hasPromptedFDA = false

    var current: FileNode { navigation.last ?? root }
    var breadcrumbs: [FileNode] { [root] + navigation }
    var visibleItems: [FileNode] {
        if query.isEmpty {
            let items = mode == .largest ? scopedFiles : current.children
            return Array(items.prefix(200))
        }
        let pool = mode == .largest || current.id != root.id ? (scopedFiles.isEmpty ? current.children : scopedFiles) : allFiles
        let needle = query.lowercased()
        var matches: [FileNode] = []
        for node in pool {
            if node.name.localizedCaseInsensitiveContains(needle) {
                matches.append(node)
                if matches.count >= 200 { break }
            }
        }
        return matches
    }
    var matchingCount: Int {
        if query.isEmpty {
            return mode == .largest ? scopedFiles.count : current.children.count
        }
        let pool = mode == .largest || current.id != root.id ? (scopedFiles.isEmpty ? current.children : scopedFiles) : allFiles
        let needle = query.lowercased()
        var count = 0
        for node in pool {
            if node.name.localizedCaseInsensitiveContains(needle) {
                count += 1
                if count >= 201 { break }
            }
        }
        return count
    }
    var largestFolder: FileNode? { current.children.first { $0.isDirectory } }
    var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }

    init() {
        let args = CommandLine.arguments
        let isTesting = args.contains("--smoke-test") || args.contains("--snapshot")
        allFiles = root.allFiles().sorted { $0.size > $1.size }
        scopedFiles = allFiles
        updateDisk(URL(fileURLWithPath: NSHomeDirectory()))

        if !isTesting, let recent = ScanIndexCache.shared.loadMostRecent() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: recent.root.url.path, isDirectory: &isDir), isDir.boolValue {
                applyScanResult(recent, url: recent.root.url)
                notice = L10n.format("notice.cached", recent.root.name)
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("panel.chooseTitle")
        panel.prompt = L10n.text("action.scan")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.requestScan(url) }
        }
    }

    func requestScan(_ url: URL, force: Bool = false) {
        let args = CommandLine.arguments
        let isTesting = args.contains("--smoke-test") || args.contains("--snapshot")
        let path = url.standardizedFileURL.path
        let isBroadScope = path == "/" || path == NSHomeDirectory() || path.hasPrefix("/Volumes")
        if !isTesting && isBroadScope && !FullDiskAccess.isGranted && !hasPromptedFDA {
            pendingScanURL = url
            showFDAPrompt = true
            hasPromptedFDA = true
            return
        }
        scan(url, force: force)
    }

    func confirmFDAScan() {
        showFDAPrompt = false
        if let url = pendingScanURL {
            pendingScanURL = nil
            scan(url)
        }
    }

    func scan(_ url: URL, force: Bool = false) {
        if !force {
            if let cached = ScanIndexCache.shared.findNodeInCachedTrees(for: url) {
                if cached.report.root.url.path == url.standardizedFileURL.path {
                    applyScanResult(cached.report, url: url)
                    notice = L10n.format("notice.cached", cached.report.root.name)
                    return
                } else if !isDemo && root.url.path == cached.report.root.url.path {
                    navigate(to: cached.node)
                    return
                }
            }
        }

        scanTask?.cancel()
        let id = UUID()
        scanID = id
        isScanning = true
        progress = nil
        notice = nil

        var targetBytes: Int64?
        if let cached = ScanIndexCache.shared.get(for: url) {
            targetBytes = cached.root.size
        } else if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
                  let total = (attrs[.systemSize] as? NSNumber)?.int64Value,
                  let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
                  total > free {
            targetBytes = total - free
        }

        let scoped = url.startAccessingSecurityScopedResource()
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.scanID == id, self.isScanning else { return }
                self.progress = update
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            try DiskScanner.scan(url, targetBytes: targetBytes, progress: onProgress)
        }
        scanTask = task
        observationTask = Task { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await task.value
                guard let self, self.scanID == id else { return }
                ScanIndexCache.shared.set(result, for: url)
                self.applyScanResult(result, url: url)
                if result.unreadableCount > 0 {
                    self.notice = L10n.format("notice.unreadable", result.unreadableCount.formatted())
                } else if result.skippedLinks > 0 {
                    self.notice = L10n.format("notice.links", result.skippedLinks.formatted())
                }
            } catch is CancellationError {
                guard let self, self.scanID == id else { return }
                self.isScanning = false
            } catch {
                guard let self, self.scanID == id else { return }
                self.isScanning = false
                self.errorMessage = L10n.format("error.scan", error.localizedDescription)
            }
        }
    }

    private func applyScanResult(_ result: ScanReport, url: URL) {
        root = result.root
        report = result
        navigation = []
        selected = nil
        query = ""
        allFiles = result.filesBySize
        scopedFiles = result.filesBySize
        isDemo = false
        isScanning = false
        updateDisk(url)
    }

    func cancelScan() {
        scanID = UUID()
        scanTask?.cancel()
        isScanning = false
        progress = nil
        notice = L10n.text("notice.cancelled")
    }

    func refresh() {
        guard !isDemo else { chooseFolder(); return }
        scan(root.url, force: true)
    }

    func enter(_ node: FileNode) {
        guard node.isDirectory else { selected = node; return }
        navigation.append(node)
        selected = nil
        query = ""
        if mode == .largest {
            updateScopedFiles()
        }
    }

    func goBack() {
        guard !navigation.isEmpty else { return }
        navigation.removeLast()
        selected = nil
        query = ""
        if mode == .largest {
            updateScopedFiles()
        }
    }

    func navigate(to node: FileNode) {
        if node.id == root.id { navigation = [] }
        else if let index = navigation.firstIndex(where: { $0.id == node.id }) {
            navigation = Array(navigation.prefix(index + 1))
        }
        selected = nil
        query = ""
        if mode == .largest {
            updateScopedFiles()
        }
    }

    private func updateScopedFiles() {
        if current.id == root.id {
            scopedFiles = allFiles
        } else {
            scopedFiles = current.allFiles().sorted { $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size }
        }
    }

    func reveal(_ node: FileNode) {
        guard !isDemo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: FileNode) {
        if node.isDirectory { enter(node) }
        else if !isDemo, !NSWorkspace.shared.open(node.url) {
            errorMessage = L10n.text("error.open")
        }
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    func moveToTrash() {
        guard let node = trashCandidate, !isDemo else { trashCandidate = nil; return }
        trashCandidate = nil
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            scan(root.url, force: true)
        } catch {
            errorMessage = L10n.format("error.trash", error.localizedDescription)
        }
    }

    private func updateDisk(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else { return }
        diskTotal = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        diskFree = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
