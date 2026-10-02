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
    @Published var query = ""
    @Published var mode: BrowserMode = .folders
    @Published var showMap = true
    @Published var errorMessage: String?
    @Published var trashCandidate: FileNode?
    @Published var notice: String?
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published private var scopedFiles: [FileNode] = []
    private var allFiles: [FileNode] = []
    private var scanTask: Task<ScanReport, Error>?
    private var scanID = UUID()
    private var observationTask: Task<Void, Never>?

    var current: FileNode { navigation.last ?? root }
    var breadcrumbs: [FileNode] { [root] + navigation }
    var visibleItems: [FileNode] {
        let items = mode == .largest || !query.isEmpty ? scopedFiles : current.children
        guard !query.isEmpty else { return Array(items.prefix(200)) }
        return Array(items.lazy.filter { $0.name.localizedCaseInsensitiveContains(self.query) }.prefix(200))
    }
    var matchingCount: Int {
        let items = mode == .largest || !query.isEmpty ? scopedFiles : current.children
        return query.isEmpty ? items.count : items.filter { $0.name.localizedCaseInsensitiveContains(query) }.count
    }
    var largestFolder: FileNode? { current.children.first { $0.isDirectory } }
    var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }

    init() {
        allFiles = root.allFiles().sorted { $0.size > $1.size }
        scopedFiles = allFiles
        updateDisk(URL(fileURLWithPath: NSHomeDirectory()))
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
            Task { @MainActor in self?.scan(url) }
        }
    }

    func scan(_ url: URL) {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        isScanning = true
        progress = nil
        notice = nil
        let scoped = url.startAccessingSecurityScopedResource()
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                guard self.scanID == id, self.isScanning else { return }
                self.progress = update
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            try DiskScanner.scan(url, progress: onProgress)
        }
        scanTask = task
        observationTask = Task { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await task.value
                guard let self, self.scanID == id else { return }
                self.root = result.root
                self.report = result
                self.navigation = []
                self.selected = nil
                self.query = ""
                self.allFiles = result.filesBySize
                self.scopedFiles = result.filesBySize
                self.isDemo = false
                self.isScanning = false
                self.updateDisk(url)
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

    func cancelScan() {
        scanID = UUID()
        scanTask?.cancel()
        isScanning = false
        progress = nil
        notice = L10n.text("notice.cancelled")
    }

    func refresh() {
        guard !isDemo else { chooseFolder(); return }
        scan(root.url)
    }

    func enter(_ node: FileNode) {
        guard node.isDirectory else { selected = node; return }
        navigation.append(node)
        resetScope()
    }

    func goBack() {
        guard !navigation.isEmpty else { return }
        navigation.removeLast()
        resetScope()
    }

    func navigate(to node: FileNode) {
        if node.id == root.id { navigation = [] }
        else if let index = navigation.firstIndex(where: { $0.id == node.id }) {
            navigation = Array(navigation.prefix(index + 1))
        }
        resetScope()
    }

    private func resetScope() {
        selected = nil
        query = ""
        let prefix = current.url.path.hasSuffix("/") ? current.url.path : current.url.path + "/"
        scopedFiles = allFiles.filter { $0.id.hasPrefix(prefix) }
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
            scan(root.url)
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
