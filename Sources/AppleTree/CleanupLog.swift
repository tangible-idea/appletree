import Foundation
import Combine
import AppleTreeCore

@MainActor
final class CleanupLogEntry: ObservableObject, Identifiable {
    enum Status: Equatable {
        case ready, cleaning, removed, skipped(CleanupSkip)
    }
    let file: CleanupFile
    let displayPath: String
    let id: String
    @Published var status: Status = .ready

    init(file: CleanupFile, home: String) {
        self.file = file
        id = file.url.path
        let path = file.url.deletingLastPathComponent().path
        displayPath = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Only the progress and log views observe this object; the main browser observes CleanupStore.
@MainActor
final class CleanupLog: ObservableObject {
    struct Summary: Equatable {
        var plannedBytes: Int64 = 0
        var removedBytes: Int64 = 0
        var removedFiles = 0
        var processedFiles = 0
        var progress = 0.0
    }

    @Published private(set) var entries: [CleanupLogEntry] = []
    @Published private(set) var findings: [MolePreview.Finding] = []
    @Published private(set) var summary = Summary()
    @Published private(set) var detail = ""
    @Published private(set) var focusedEntryID: String?
    private(set) var entriesVersion: UInt64 = 0
    private var entriesByPath: [String: CleanupLogEntry] = [:]
    private let home: String

    init(home: String) { self.home = home }

    func reset() {
        entriesVersion &+= 1
        entries = []
        entriesByPath = [:]
        findings = []
        summary = Summary()
        detail = ""
        focusedEntryID = nil
    }

    func setDetail(_ text: String) {
        if detail != text { detail = text }
    }

    func complete() {
        var next = summary
        next.progress = entries.isEmpty ? 1 : Double(next.processedFiles) / Double(entries.count)
        if next != summary { summary = next }
    }

    func apply(_ updates: [CleanupUpdate]) {
        var next = summary
        var newEntries: [CleanupLogEntry] = []
        var newFindings: [MolePreview.Finding] = []
        var latestDetail = detail
        var focused = focusedEntryID
        for update in updates {
            switch update {
            case .detail(let text): latestDetail = text
            case .finding(let finding): newFindings.append(finding)
            case .found(let file):
                let path = file.url.path
                guard entriesByPath[path] == nil else { continue }
                let entry = CleanupLogEntry(file: file, home: home)
                entriesByPath[path] = entry
                newEntries.append(entry)
                next.plannedBytes += file.size
            case .execution(let event):
                switch event {
                case .removing(let file):
                    guard let entry = entriesByPath[file.url.path], entry.status == .ready else { continue }
                    entry.status = .cleaning
                    focused = entry.id
                    latestDetail = entry.id.hasPrefix(home + "/") ? "~" + entry.id.dropFirst(home.count) : entry.id
                case .finished(let file, let reason):
                    guard let entry = entriesByPath[file.url.path], entry.status == .ready || entry.status == .cleaning else { continue }
                    entry.status = reason.map { .skipped($0) } ?? .removed
                    focused = entry.id
                    next.processedFiles += 1
                    if reason == nil { next.removedBytes += file.size; next.removedFiles += 1 }
                }
            }
        }
        // Membership changes once per discovery batch. Status changes touch only their own row.
        if !newEntries.isEmpty {
            entriesVersion &+= 1
            entries.append(contentsOf: newEntries)
        }
        if !newFindings.isEmpty { findings.append(contentsOf: newFindings) }
        next.progress = entries.isEmpty ? 0 : Double(next.processedFiles) / Double(entries.count)
        if next != summary { summary = next }
        if focused != focusedEntryID { focusedEntryID = focused }
        setDetail(latestDetail)
    }
}

enum CleanupUpdate: Sendable {
    case detail(String)
    case finding(MolePreview.Finding)
    case found(CleanupFile)
    case execution(CleanupEvent)
}

/// Keeps every discovery/outcome, but coalesces transient paths and refreshes at most four times a second.
final class CleanupReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CleanupUpdate] = []
    private var pendingDetail: String?
    private var scheduled = false
    private let apply: @MainActor ([CleanupUpdate]) -> Void

    init(apply: @escaping @MainActor ([CleanupUpdate]) -> Void) { self.apply = apply }

    func send(_ update: CleanupUpdate) {
        lock.lock()
        if case .detail(let text) = update { pendingDetail = text }
        else { pending.append(update) }
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.flush()
        }
    }

    @MainActor func flush() {
        lock.lock()
        var updates = pending
        pending = []
        if let pendingDetail { updates.append(.detail(pendingDetail)) }
        pendingDetail = nil
        scheduled = false
        lock.unlock()
        if !updates.isEmpty { apply(updates) }
    }
}
