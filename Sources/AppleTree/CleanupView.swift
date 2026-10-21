import SwiftUI
import AppKit
import AppleTreeCore

struct CleanupOptions: View {
    @EnvironmentObject private var cleanup: CleanupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(CleanupCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(category.title, isOn: Binding(get: { cleanup.settings.categories.contains(category) }, set: { enabled in
                        if enabled { cleanup.settings.categories.insert(category) }
                        else { cleanup.settings.categories.remove(category) }
                    }))
                    Text(category.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 10) {
                retentionPicker("cleanup.age.caches", selection: $cleanup.settings.cacheAgeDays, days: [7, 14, 30])
                retentionPicker("cleanup.age.logs", selection: $cleanup.settings.logAgeDays, days: [30, 60, 90])
            }
            Text(L10n.text("cleanup.scope.note")).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(L10n.text("cleanup.protect.title")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.text("cleanup.protect.add")) { cleanup.protectFolder() }.font(.system(size: 11))
            }
            ForEach(cleanup.settings.protectedPaths, id: \.self) { path in
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.green)
                    Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Button { cleanup.settings.protectedPaths.removeAll { $0 == path } } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.plain).help(L10n.text("cleanup.protect.remove"))
                }
            }
            Text(L10n.text("cleanup.protect.note")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .disabled(cleanup.isBusy)
    }

    private func retentionPicker(_ key: String, selection: Binding<Int>, days: [Int]) -> some View {
        HStack {
            Text(L10n.text(key)).font(.system(size: 12))
            Spacer()
            Picker(L10n.text(key), selection: selection) {
                ForEach(days, id: \.self) { value in
                    Text(L10n.format("cleanup.age.days", value.formatted())).tag(value)
                }
            }.labelsHidden().frame(width: 130)
        }
    }
}

struct CleanupSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var cleanup: CleanupStore
    @State private var optionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("cleanup.title")).font(.system(size: 22, weight: .bold))
                    Text(L10n.text("cleanup.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if cleanup.moleURL == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text("cleanup.mole.missing")).font(.system(size: 13, weight: .semibold))
                            Text(L10n.text("cleanup.mole.installNote")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            HStack {
                                Text("brew install mole").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button(L10n.text("cleanup.mole.copy")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("brew install mole", forType: .string)
                                }
                            }
                            Button(L10n.text("cleanup.mole.retry")) { cleanup.open() }
                        }
                    }
                    if cleanup.isBusy {
                        CleanupProgress()
                    }
                    if cleanup.selectedHistory == nil,
                       cleanup.isBusy || !cleanup.logEntries.isEmpty || !cleanup.findings.isEmpty {
                        CleanupLogView()
                    }
                    if let error = cleanup.errorMessage {
                        Label(error, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    if let result = cleanup.selectedHistory ?? cleanup.result {
                        if !cleanup.isBusy && cleanup.logEntries.isEmpty {
                            Text(L10n.text("cleanup.last")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                        CleanupResultView(result: result)
                    }
                    if cleanup.historyError {
                        Text(L10n.text("cleanup.history.failed")).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    DisclosureGroup(L10n.text("cleanup.scope.title"), isExpanded: $optionsExpanded) {
                        CleanupOptions().padding(.top, 12)
                    }.font(.system(size: 13, weight: .semibold))
                    if cleanup.history.count > 1 {
                        DisclosureGroup(L10n.text("cleanup.history.title")) {
                            VStack(spacing: 10) {
                                ForEach(cleanup.history) { record in
                                    Button { cleanup.selectedHistory = record } label: {
                                        HStack {
                                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                            Spacer()
                                            Text(L10n.format("cleanup.history.bytes", SizeText.format(record.removedBytes)))
                                            Image(systemName: "chevron.right")
                                        }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.top, 10)
                        }.font(.system(size: 12, weight: .semibold))
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Button(L10n.text("cleanup.close")) { cleanup.showSheet = false }.buttonStyle(QuietButtonStyle())
                Spacer()
                if cleanup.canCancel {
                    Button(L10n.text("action.cancel")) { cleanup.cancel() }.buttonStyle(QuietButtonStyle())
                }
                Button(cleanup.isBusy ? cleanup.phase.buttonTitle : L10n.text(cleanup.configured ? "cleanup.start" : "cleanup.firstStart")) {
                    cleanup.selectedHistory = nil
                    optionsExpanded = false
                    cleanup.start { await store.refreshAfterCleanup() }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(cleanup.isBusy || cleanup.moleURL == nil || cleanup.settings.categories.isEmpty || store.isScanning || store.exportProgress != nil)
            }.padding(20)
        }
        .frame(width: 680, height: 680)
        .foregroundStyle(Theme.ink).background(Theme.background)
        .preferredColorScheme(.light)
        .onAppear { optionsExpanded = !cleanup.configured && cleanup.selectedHistory == nil }
        .interactiveDismissDisabled(cleanup.isBusy)
    }
}

/// Toolbar control: the cleanup action on the left, recent cleanup history on the right.
struct CleanupSplitButton: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var cleanup: CleanupStore
    @State private var showHistory = false

    var body: some View {
        HStack(spacing: 0) {
            Button { store.smartClean() } label: {
                Label(L10n.text("cleanup.title"), systemImage: "sparkles")
                    .padding(.horizontal, 13).padding(.vertical, 9).contentShape(Rectangle())
            }
            .disabled(store.isScanning || store.exportProgress != nil)
            Rectangle().fill(Theme.line).frame(width: 1, height: 20)
            Button { showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
            }
            .help(L10n.text("cleanup.history.title"))
            .popover(isPresented: $showHistory, arrowEdge: .bottom) { history }
        }
        .buttonStyle(SegmentButtonStyle())
        .foregroundStyle(Theme.ink)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("cleanup.history.title")).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if cleanup.history.isEmpty {
                Text(L10n.text("cleanup.history.empty")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                ForEach(cleanup.history) { record in
                    Button {
                        showHistory = false
                        cleanup.open(history: record)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12))
                                Text(L10n.count(.files, record.removedFiles)).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Text(SizeText.format(record.removedBytes)).font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(record.cancelled ? Theme.secondary : Theme.accent)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: 280)
        .foregroundStyle(Theme.ink).background(Theme.background)
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.line : .clear)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct CleanupProgress: View {
    @EnvironmentObject private var cleanup: CleanupStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().controlSize(.small)
                Text(cleanup.phase.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if cleanup.phase == .cleaning {
                    Text(cleanup.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.accent)
                }
            }
            if cleanup.phase == .cleaning { ProgressView(value: cleanup.progress).tint(Theme.accent) }
            if cleanup.phase == .cleaning || cleanup.phase == .refreshing {
                Text(L10n.format("cleanup.log.progress", SizeText.format(cleanup.removedBytes), SizeText.format(cleanup.plannedBytes)))
                    .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.green)
            }
            if !cleanup.detail.isEmpty {
                Text(cleanup.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle).help(cleanup.detail)
            }
        }
    }
}

private struct CleanupLogView: View {
    @EnvironmentObject private var cleanup: CleanupStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("cleanup.log.title")).font(.system(size: 13, weight: .semibold))
            if cleanup.phase != .discovering {
                HStack(alignment: .top, spacing: 24) {
                    metric(cleanup.planComplete ? "cleanup.log.planned" : (cleanup.isBusy ? "cleanup.log.confirmed" : "cleanup.log.partial"), bytes: cleanup.plannedBytes)
                    metric("cleanup.log.removed", bytes: cleanup.removedBytes, color: Theme.green)
                }
                Text(L10n.format("cleanup.removed", SizeText.format(cleanup.removedBytes), cleanup.removedFiles.formatted()))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            if cleanup.phase == .discovering || cleanup.logEntries.isEmpty {
                if cleanup.findings.isEmpty {
                    Text(L10n.text("cleanup.log.waiting")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                } else {
                    discoveryLog
                }
            } else {
                fileLog
                if !cleanup.findings.isEmpty {
                    DisclosureGroup(L10n.text("cleanup.log.discovery")) { discoveryLog.padding(.top, 8) }
                        .font(.system(size: 11))
                }
            }
            Text(L10n.text("cleanup.log.sizeNote")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private func metric(_ key: String, bytes: Int64, color: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(key)).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            Text(SizeText.format(bytes)).font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var discoveryLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(cleanup.findings.enumerated()), id: \.offset) { index, finding in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.name).font(.system(size: 11, weight: .medium))
                                Text(L10n.text("cleanup.log.estimate")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(finding.size).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        }.id(index)
                    }
                }.padding(.trailing, 8)
            }
            .frame(height: min(220, CGFloat(cleanup.findings.count) * 44))
            .onChange(of: cleanup.findings.count) { _, count in
                if cleanup.phase == .discovering { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private var fileLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(cleanup.logEntries) { entry in
                        CleanupLogRow(entry: entry, isBusy: cleanup.isBusy).id(entry.id)
                    }
                }.padding(.trailing, 8)
            }
            .frame(height: min(240, CGFloat(cleanup.logEntries.count) * 60))
            .onChange(of: cleanup.logEntries.count) { _, _ in
                if let last = cleanup.logEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: cleanup.detail) { _, _ in
                if cleanup.phase == .cleaning,
                   let current = cleanup.logEntries.first(where: { if case .cleaning = $0.status { return true }; return false }) {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }
}

private struct CleanupLogRow: View {
    let entry: CleanupLogEntry
    let isBusy: Bool

    private var appearance: (key: String, icon: String, color: Color) {
        switch entry.status {
        case .ready: (isBusy ? "cleanup.log.ready" : "cleanup.log.kept", "doc", Theme.secondary)
        case .cleaning: ("cleanup.log.cleaning", "sparkles", Theme.accent)
        case .removed: ("cleanup.log.deleted", "checkmark.circle.fill", Theme.green)
        case .skipped: ("cleanup.log.kept", "minus.circle", Theme.secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: appearance.icon).foregroundStyle(appearance.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.file.url.lastPathComponent).font(.system(size: 11, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(L10n.text(appearance.key) + " · " + SizeText.format(entry.file.size))
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(appearance.color).fixedSize()
                }
                Text(entry.file.category.title + " · " + entry.displayPath)
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.middle).help(entry.file.url.path)
                if case .skipped(let reason) = entry.status {
                    Text(reason.title).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

struct CleanupSummaryCard: View {
    @EnvironmentObject private var cleanup: CleanupStore
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: cleanup.isBusy ? "sparkles" : "checkmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 6) {
                if cleanup.isBusy {
                    CleanupProgress()
                } else if let result = cleanup.result {
                    Text(L10n.text("cleanup.last")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    Text(L10n.text(result.cancelled ? "cleanup.stopped" : "cleanup.done"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.format("cleanup.removed", SizeText.format(result.removedBytes), result.removedFiles.formatted()))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(result.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            Button(L10n.text("cleanup.details")) { cleanup.open() }.buttonStyle(QuietButtonStyle())
        }
        .padding(18).background(Theme.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.green.opacity(0.15), lineWidth: 1))
    }
}

struct CleanupResultView: View {
    let result: CleanupResult
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(result.cancelled ? "cleanup.stopped" : "cleanup.done"))
                .font(.system(size: 18, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("cleanup.result.removed")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(SizeText.format(result.removedBytes)).font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                    Text(L10n.count(.files, result.removedFiles)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("cleanup.result.free")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(result.freeDelta.map { ($0 >= 0 ? "+" : "−") + SizeText.format(abs($0)) } ?? "—")
                        .font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(Theme.green)
                    Text(L10n.text("cleanup.result.freeNote")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            Text(result.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if let planned = result.plannedBytes {
                HStack {
                    Text(L10n.text("cleanup.result.planned"))
                    Spacer()
                    Text(SizeText.format(planned)).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Divider()
            Text(L10n.text("cleanup.map.title")).font(.system(size: 13, weight: .semibold))
            ForEach(CleanupCategory.allCases) { category in
                let before = result.before[category] ?? 0
                let after = max(0, before - (result.removed[category] ?? 0))
                if before > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.title).font(.system(size: 11, weight: .medium))
                        spaceBar(label: L10n.text("cleanup.map.before"), size: before, total: before, color: Theme.accent.opacity(0.5))
                        spaceBar(label: L10n.text("cleanup.map.after"), size: after, total: before, color: Theme.green)
                    }
                }
            }
            Text(L10n.text("cleanup.map.note")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if result.removedFiles == 0 { Text(L10n.text("cleanup.result.empty")).font(.system(size: 12)) }
            if result.skippedCount > 0 {
                Divider()
                Text(L10n.format("cleanup.skipped", result.skippedCount.formatted())).font(.system(size: 12, weight: .semibold))
                ForEach(CleanupSkip.allCases, id: \.self) { reason in
                    if let count = result.skipped[reason], count > 0 {
                        HStack {
                            Text(reason.title)
                            Spacer()
                            Text(count.formatted())
                        }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func spaceBar(label: String, size: Int64, total: Int64, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 44, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(color).frame(width: proxy.size.width * (total > 0 ? Double(size) / Double(total) : 0))
                }
            }.frame(height: 7)
            Text(SizeText.format(size)).frame(width: 78, alignment: .trailing)
        }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
    }
}
