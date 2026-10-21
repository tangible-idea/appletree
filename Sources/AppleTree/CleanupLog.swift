import Foundation
import AppleTreeCore

struct CleanupLogEntry: Identifiable {
    enum Status {
        case ready, cleaning, removed, skipped(CleanupSkip)
    }
    let file: CleanupFile
    let displayPath: String
    var status: Status = .ready
    var id: String { file.url.path }
}

enum CleanupUpdate: Sendable {
    case detail(String)
    case finding(MolePreview.Finding)
    case found(CleanupFile)
    case execution(CleanupEvent)
}

/// Batches background events without dropping discoveries or successful removals.
final class CleanupReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CleanupUpdate] = []
    private var scheduled = false
    private let apply: @MainActor ([CleanupUpdate]) -> Void

    init(apply: @escaping @MainActor ([CleanupUpdate]) -> Void) { self.apply = apply }

    func send(_ update: CleanupUpdate) {
        lock.lock()
        pending.append(update)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.flush()
        }
    }

    @MainActor func flush() {
        lock.lock()
        let updates = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        if !updates.isEmpty { apply(updates) }
    }
}
