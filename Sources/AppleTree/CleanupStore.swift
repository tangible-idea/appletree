import AppKit
import SwiftUI
import AppleTreeCore

@MainActor
final class CleanupStore: ObservableObject {
    enum Phase: String {
        case idle, discovering, checking, cleaning, refreshing
        var title: String { L10n.text("cleanup.phase.\(rawValue)") }
    }

    @Published var showSheet = false
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
            if history.isEmpty { history = Array(records.prefix(10)); result = history.first }
        }
    }

    func open() {
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
        phase = .discovering
        let settings = settings
        task = Task { [weak self] in
            guard let self else { return }
            defer { phase = .idle; detail = ""; task = nil; deletionTask = nil }
            do {
                let cleaner = self.cleaner
                let home = cleaner.home.path
                let reporter = DetailReporter { [weak self] text in self?.detail = text }
                let patterns = try MolePreview.protectedPatterns(home: cleaner.home)
                let paths = try await MolePreview.discover(executable: moleURL, home: cleaner.home) { line in
                    if let text = Self.describe(output: line, home: home) { reporter.send(text) }
                }
                try Task.checkCancellation()
                reporter.flush()
                phase = .checking
                detail = L10n.text("cleanup.detail.activity")
                let activity = try await Self.activity()
                let planner = Task.detached(priority: .utility) {
                    try cleaner.plan(paths: paths, settings: settings, activity: activity, moleProtection: patterns) { url in
                        reporter.send(Self.shorten(url.path, home: home))
                    }
                }
                let plan = try await withTaskCancellationHandler { try await planner.value } onCancel: { planner.cancel() }
                try Task.checkCancellation()
                // A second snapshot catches apps/files opened while the plan was being measured.
                reporter.flush()
                detail = L10n.text("cleanup.detail.activity")
                let currentActivity = try await Self.activity()
                let currentProtection = try MolePreview.protectedPatterns(home: cleaner.home)
                try Task.checkCancellation()
                phase = .cleaning
                detail = ""
                let deletion = Task.detached(priority: .utility) { [weak self] in
                    cleaner.execute(plan, activity: currentActivity, additionalProtection: currentProtection, progress: { completed, total in
                        Task { @MainActor in
                            self?.progress = total > 0 ? Double(completed) / Double(total) : 1
                        }
                    }, current: { url in reporter.send(Self.shorten(url.path, home: home)) })
                }
                deletionTask = deletion
                let finished = await withTaskCancellationHandler { await deletion.value } onCancel: { deletion.cancel() }
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
        let text = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Delivers the latest background status to the main actor at most a few times per second.
private final class DetailReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: String?
    private var scheduled = false
    private let apply: @MainActor (String) -> Void

    init(apply: @escaping @MainActor (String) -> Void) { self.apply = apply }

    func send(_ text: String) {
        lock.lock()
        pending = text
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.deliver()
        }
    }

    /// Drops anything still queued so a later phase's text is not overwritten.
    func flush() {
        lock.lock(); pending = nil; lock.unlock()
    }

    @MainActor private func deliver() {
        lock.lock()
        let text = pending
        pending = nil
        scheduled = false
        lock.unlock()
        if let text { apply(text) }
    }
}
