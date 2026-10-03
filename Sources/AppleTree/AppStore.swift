import AppKit
import SwiftUI
import AppleTreeCore

enum BrowserMode: String, CaseIterable {
    case folders, largest

    var title: String { L10n.text("browser.\(rawValue)") }
}

enum MapStyle: String, CaseIterable {
    case sunburst, treemap

    var title: String { L10n.text("map.style.\(rawValue)") }
    var symbol: String { self == .sunburst ? "circle.circle" : "square.grid.2x2" }
}

/// One line of the folder outline. A row with `hiddenCount` stands for the
/// children of `node` that were left out of an expanded folder.
struct OutlineRow: Identifiable {
    let node: FileNode
    let depth: Int
    var hiddenCount = 0
    var id: String { hiddenCount > 0 ? node.id + "#more" : node.id }
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
        didSet { if query != oldValue { scheduleSearch(debounce: true) } }
    }
    @Published var kindFilter: Set<FileKind> = [] {
        didSet { if kindFilter != oldValue { scheduleSearch() } }
    }
    @Published var preset: SearchPreset? {
        didSet { if preset != oldValue { scheduleSearch() } }
    }
    @Published var mode: BrowserMode = .folders {
        didSet { if mode != oldValue { scheduleSearch() } }
    }
    @Published private(set) var results = SearchResult()
    @Published private(set) var isSearching = false
    @Published var expanded: Set<String> = []
    @Published var mapStyle: MapStyle = .sunburst
    @Published var showMap = true
    @Published var errorMessage: String?
    @Published var trashCandidate: FileNode?
    @Published var notice: String?
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published var showFDAPrompt = false
    private var indexTask: Task<SearchIndex, Never>?
    private var searchTask: Task<Void, Never>?
    private var sunburstCache: (id: String, arcs: [SunburstArc])?
    private var scanTask: Task<ScanReport, Error>?
    private var scanID = UUID()
    private var observationTask: Task<Void, Never>?
    private var pendingScanURL: URL?
    private var hasPromptedFDA = false

    var current: FileNode { navigation.last ?? root }
    var breadcrumbs: [FileNode] { [root] + navigation }
    var searchQuery: SearchQuery { SearchQuery(text: query, kinds: kindFilter, preset: preset) }
    var hasFilters: Bool { !searchQuery.isEmpty }
    /// Flat index results replace the folder outline when filtering or listing the largest files.
    var isShowingResults: Bool { mode == .largest || hasFilters }
    var visibleItems: [FileNode] {
        isShowingResults ? results.items : Array(current.children.prefix(Self.rowLimit))
    }
    var matchingCount: Int { isShowingResults ? results.totalCount : current.children.count }

    nonisolated static let rowLimit = 200
    nonisolated static let nestedRowLimit = 100

    /// Current folder's children with expanded folders unfolded in place.
    var outlineRows: [OutlineRow] {
        if isShowingResults { return results.items.map { OutlineRow(node: $0, depth: 0) } }
        var rows: [OutlineRow] = []
        func add(_ children: [FileNode], depth: Int, limit: Int, parent: FileNode) {
            for child in children.prefix(limit) {
                rows.append(OutlineRow(node: child, depth: depth))
                if child.isDirectory && expanded.contains(child.id) {
                    add(child.children, depth: depth + 1, limit: Self.nestedRowLimit, parent: child)
                }
            }
            if depth > 0 && children.count > limit {
                rows.append(OutlineRow(node: parent, depth: depth, hiddenCount: children.count - limit))
            }
        }
        add(current.children, depth: 0, limit: Self.rowLimit, parent: current)
        return rows
    }

    func toggleExpanded(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    func clearFilters() {
        query = ""
        kindFilter = []
        preset = nil
    }

    func toggleKind(_ kind: FileKind) {
        if kindFilter.contains(kind) { kindFilter.remove(kind) } else { kindFilter.insert(kind) }
    }

    var sunburstArcs: [SunburstArc] {
        let node = current
        if let cache = sunburstCache, cache.id == node.id { return cache.arcs }
        let arcs = Sunburst.layout(root: node)
        sunburstCache = (node.id, arcs)
        return arcs
    }

    private func rebuildIndex() {
        let root = root
        indexTask = Task.detached(priority: .userInitiated) { SearchIndex(root: root) }
        scheduleSearch()
    }

    private func scheduleSearch(debounce: Bool = false) {
        searchTask?.cancel()
        guard isShowingResults else {
            results = SearchResult()
            isSearching = false
            return
        }
        let query = searchQuery
        let scope = current
        let indexTask = indexTask
        isSearching = true
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
            guard let index = await indexTask?.value, !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                index.search(query, in: scope, limit: AppStore.rowLimit)
            }.value
            guard let self, !Task.isCancelled else { return }
            // Small result sets animate in; very large swaps stay instant to keep typing smooth.
            withAnimation(result.items.count <= 60 && self.results.items.count <= 60 ? .easeOut(duration: 0.2) : nil) {
                self.results = result
            }
            self.isSearching = false
        }
    }

    /// Lets diagnostics wait for the debounced background search to land.
    func waitForSearch() async {
        await searchTask?.value
    }

    var largestFolder: FileNode? { current.children.first { $0.isDirectory } }
    var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }

    init() {
        let args = CommandLine.arguments
        let isTesting = args.contains("--smoke-test") || args.contains("--snapshot")
        rebuildIndex()
        updateDisk(URL(fileURLWithPath: NSHomeDirectory()))

        guard !isTesting else { return }
        let id = UUID()
        scanID = id
        isScanning = true
        Task {
            let recent = await ScanIndexCache.shared.loadMostRecent()
            guard scanID == id else { return }
            var isDir: ObjCBool = false
            if let recent, FileManager.default.fileExists(atPath: recent.root.url.path, isDirectory: &isDir), isDir.boolValue {
                applyScanResult(recent, url: recent.root.url)
                notice = L10n.format("notice.cached", recent.root.name)
            } else {
                isScanning = false
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
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        isScanning = true
        progress = nil
        notice = nil
        guard !force else { startScan(url, id: id); return }

        // Loading a cached tree can take a moment for a whole disk, so it happens off the main thread.
        Task {
            let cached = await ScanIndexCache.shared.findNodeInCachedTrees(for: url)
            guard scanID == id else { return }
            guard let cached else { startScan(url, id: id); return }
            if cached.report.root !== root || isDemo {
                applyScanResult(cached.report, url: cached.report.root.url)
                notice = L10n.format("notice.cached", cached.report.root.name)
            }
            isScanning = false
            if cached.node !== root {
                navigation = Self.ancestors(of: cached.node, in: root)
                selected = nil
                leaveFolderFilters()
            }
        }
    }

    /// Folders from just below `root` down to `node`, for jumping straight into a cached subfolder.
    private static func ancestors(of node: FileNode, in root: FileNode) -> [FileNode] {
        let target = node.url.path
        var chain: [FileNode] = []
        var cursor = root
        while cursor !== node {
            guard let next = cursor.children.first(where: {
                $0.isDirectory && (target == $0.url.path || target.hasPrefix($0.url.path + "/"))
            }) else { return [] }
            chain.append(next)
            cursor = next
        }
        return chain
    }

    private func startScan(_ url: URL, id: UUID) {
        var targetBytes: Int64?
        if let cached = ScanIndexCache.shared.cachedSize(for: url) {
            targetBytes = cached
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
        let changed = result.root !== root
        root = result.root
        report = result
        navigation = []
        selected = nil
        query = ""
        preset = nil
        expanded = []
        sunburstCache = nil
        isDemo = false
        isScanning = false
        if changed { rebuildIndex() } else { scheduleSearch() }
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
        leaveFolderFilters()
    }

    func goBack() {
        guard !navigation.isEmpty else { return }
        navigation.removeLast()
        selected = nil
        leaveFolderFilters()
    }

    func navigate(to node: FileNode) {
        if node.id == root.id { navigation = [] }
        else if let index = navigation.firstIndex(where: { $0.id == node.id }) {
            navigation = Array(navigation.prefix(index + 1))
        }
        selected = nil
        leaveFolderFilters()
    }

    /// Moving between folders keeps the kind filter but drops one-off name searches and presets.
    private func leaveFolderFilters() {
        query = ""
        preset = nil
        scheduleSearch()
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
