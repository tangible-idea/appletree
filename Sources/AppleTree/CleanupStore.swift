import AppKit
import SwiftUI
import AppleTreeCore

@MainActor
final class CleanupStore: ObservableObject {
    enum Phase: String {
        case idle, discovering, checking, cleaning, refreshing
        var title: String { L10n.text("cleanup.phase.\(rawValue)") }
        /// Short label for the start button while this phase runs.
        var buttonTitle: String {
            switch self {
            case .idle: return L10n.text("cleanup.start")
            case .discovering, .checking: return L10n.text("cleanup.button.checking")
            case .cleaning: return L10n.text("cleanup.button.cleaning")
            case .refreshing: return L10n.text("cleanup.button.refreshing")
            }
        }
    }

    @Published var showSheet = false
    /// A past run picked from the history list; the sheet shows it instead of the latest result.
    @Published var selectedHistory: CleanupResult?
    @Published var settings: CleanupSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        }
    }
    @Published private(set) var configured: Bool
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = 0.0
    /// What the cleanup is currently looking at, so long phases show visible movement.
    @Published private(set) var detail = ""
    @Published private(set) var logEntries: [CleanupLogEntry] = []
    @Published private(set) var findings: [MolePreview.Finding] = []
    @Published private(set) var plannedBytes: Int64 = 0
    @Published private(set) var removedBytes: Int64 = 0
    @Published private(set) var removedFiles = 0
    @Published private(set) var planComplete = false
    private var logIndices: [String: Int] = [:]
    private var processedFiles = 0
    @Published private(set) var result: CleanupResult?
    @Published private(set) var history: [CleanupResult] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyError = false
    @Published private(set) var moleURL: URL?
    private var task: Task<Void, Never>?
    private var deletionTask: Task<CleanupResult, Never>?
    private let defaults: UserDefaults
    private let historyURL: URL
    private let cleaner: SmartCleanup
    static let settingsKey = "smartCleanupSettings"
    private static let configuredKey = "smartCleanupConfigured"
    var isBusy: Bool { phase != .idle }
    var canCancel: Bool { isBusy && phase != .refreshing }

    init(defaults: UserDefaults = .standard, historyURL: URL? = nil, home: URL? = nil, executable: URL? = nil) {
        self.defaults = defaults
        self.cleaner = SmartCleanup(home: home ?? FileManager.default.homeDirectoryForCurrentUser)
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(CleanupSettings.self, from: $0) } ?? CleanupSettings()
        configured = defaults.bool(forKey: Self.configuredKey)
        moleURL = executable ?? MolePreview.locate()
        self.historyURL = historyURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleTree/cleanup-history.json")
        let url = self.historyURL
        Task {
            let records = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([CleanupResult].self, from: $0) } ?? []
            }.value
            if history.isEmpty {
                history = Array(records.prefix(10))
                if !isBusy, result == nil { result = history.first }
            }
        }
    }

    func open(history record: CleanupResult? = nil) {
        selectedHistory = record
        moleURL = MolePreview.locate()
        errorMessage = nil
        showSheet = true
    }

    func protectFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("cleanup.protect.add")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                self.settings.protectedPaths = Array(Set(self.settings.protectedPaths + panel.urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })).sorted()
            }
        }
    }

    func start(afterCleanup: @escaping @MainActor () async -> Void) {
        guard !isBusy, let moleURL, !settings.categories.isEmpty else { return }
        configured = true
        defaults.set(true, forKey: Self.configuredKey)
        errorMessage = nil
        historyError = false
        result = nil
        progress = 0
        detail = ""
        logEntries = []
        logIndices = [:]
        findings = []
        plannedBytes = 0
        removedBytes = 0
        removedFiles = 0
        processedFiles = 0
        planComplete = false
        phase = .discovering
        let settings = settings
        task = Task { [weak self] in
            guard let self else { return }
            let reporter = CleanupReporter { [weak self] updates in self?.apply(updates) }
            defer {
                reporter.flush()
                phase = .idle; detail = ""; task = nil; deletionTask = nil
            }
            do {
                let cleaner = self.cleaner
                let home = cleaner.home.path
                let patterns = try MolePreview.protectedPatterns(home: cleaner.home)
                let paths = try await MolePreview.discover(executable: moleURL, home: cleaner.home) { line in
                    if let finding = MolePreview.finding(in: line) { reporter.send(.finding(finding)) }
                    else if let text = Self.describe(output: line, home: home) { reporter.send(.detail(text)) }
                }
                try Task.checkCancellation()
                reporter.flush()
                phase = .checking
                detail = L10n.text("cleanup.detail.activity")
                let activity = try await Self.activity()
                let planner = Task.detached(priority: .utility) {
                    try cleaner.plan(paths: paths, settings: settings, activity: activity, moleProtection: patterns,
                                     found: { reporter.send(.found($0)) },
                                     progress: { reporter.send(.detail(Self.shorten($0.path, home: home))) })
                }
                let plan = try await withTaskCancellationHandler { try await planner.value } onCancel: { planner.cancel() }
                try Task.checkCancellation()
                // A second snapshot catches apps/files opened while the plan was being measured.
                reporter.flush()
                planComplete = true
                detail = L10n.text("cleanup.detail.activity")
                let currentActivity = try await Self.activity()
                let currentProtection = try MolePreview.protectedPatterns(home: cleaner.home)
                try Task.checkCancellation()
                phase = .cleaning
                detail = ""
                let deletion = Task.detached(priority: .utility) {
                    cleaner.execute(plan, activity: currentActivity, additionalProtection: currentProtection,
                                    event: { reporter.send(.execution($0)) })
                }
                deletionTask = deletion
                let finished = await withTaskCancellationHandler { await deletion.value } onCancel: { deletion.cancel() }
                reporter.flush()
                progress = plan.files.isEmpty ? 1 : Double(processedFiles) / Double(plan.files.count)
                result = finished
                history.insert(finished, at: 0)
                history = Array(history.prefix(10))
                reporter.flush()
                await saveHistory()
                phase = .refreshing
                detail = ""
                await afterCleanup()
            } catch is CancellationError {
                errorMessage = L10n.text("cleanup.cancelledBefore")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard canCancel else { return }
        deletionTask?.cancel()
        task?.cancel()
    }

    private func apply(_ updates: [CleanupUpdate]) {
        // Publish once per batch, even when many small files are discovered together.
        var entries = logEntries
        var discoveries = findings
        var planned = plannedBytes
        var removed = removedBytes
        var count = removedFiles
        var latestDetail = detail
        for update in updates {
            switch update {
            case .detail(let text): latestDetail = text
            case .finding(let finding): discoveries.append(finding)
            case .found(let file):
                guard logIndices[file.url.path] == nil else { continue }
                logIndices[file.url.path] = entries.count
                entries.append(CleanupLogEntry(file: file, displayPath: Self.shorten(file.url.deletingLastPathComponent().path, home: cleaner.home.path)))
                planned += file.size
            case .execution(let event):
                switch event {
                case .removing(let file):
                    if let index = logIndices[file.url.path] { entries[index].status = .cleaning }
                    latestDetail = Self.shorten(file.url.path, home: cleaner.home.path)
                case .finished(let file, let reason):
                    guard let index = logIndices[file.url.path] else { continue }
                    entries[index].status = reason.map { .skipped($0) } ?? .removed
                    processedFiles += 1
                    if reason == nil { removed += file.size; count += 1 }
                }
            }
        }
        logEntries = entries
        findings = discoveries
        plannedBytes = planned
        removedBytes = removed
        removedFiles = count
        detail = latestDetail
        if phase == .cleaning { progress = entries.isEmpty ? 1 : Double(processedFiles) / Double(entries.count) }
    }

    private func saveHistory() async {
        let records = history
        let url = historyURL
        historyError = await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(records).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return false
            } catch { return true }
        }.value
    }

    nonisolated private static func shorten(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Turns a line of the discovery tool's output into user-facing text, hiding the tool's own branding.
    nonisolated private static func describe(output line: String, home: String) -> String? {
        let text = MolePreview.cleanOutput(line)
        guard !text.isEmpty, text.range(of: "mole", options: .caseInsensitive) == nil,
              !text.hasPrefix("#") else { return nil }
        return shorten(text.replacingOccurrences(of: home + "/", with: "~/"), home: home)
    }

    private static func activity() async throws -> CleanupActivity {
        let apps = NSWorkspace.shared.runningApplications
        let identifiers = Set(apps.compactMap(\.bundleIdentifier))
        let names = Set(apps.compactMap(\.localizedName))
        let openFiles = try await CleanupCommand.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                                   arguments: ["-nP", "-F", "n", "-u", String(getuid())], timeout: 30)
        let paths = Set(openFiles.text.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("n/") else { return nil }
            return String(line.dropFirst())
        })
        guard !paths.isEmpty, openFiles.status == 0 || openFiles.status == 1 else {
            throw CleanupFailure("cleanup.error.activity")
        }
        let processes = try await CleanupCommand.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "comm="])
        guard processes.status == 0 else { throw CleanupFailure("cleanup.error.activity") }
        var tools: Set<String> = []
        for line in processes.text.components(separatedBy: .newlines) {
            let name = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased()
            if name == "node" || name == "npm" || name == "yarn" { tools.insert("node") }
            if name.hasPrefix("python") || name.hasPrefix("pip") { tools.insert("python") }
            if name == "brew" { tools.insert("brew") }
            if name == "go" { tools.insert("go") }
        }
        return CleanupActivity(openPaths: paths, appIdentifiers: identifiers, appNames: names, busyTools: tools)
    }
}
