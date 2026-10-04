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
    @State private var selectedHistory: CleanupResult?

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
                    if let error = cleanup.errorMessage {
                        Label(error, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    if let result = selectedHistory ?? cleanup.result {
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
                                    Button { selectedHistory = record } label: {
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
                Button(L10n.text(cleanup.configured ? "cleanup.start" : "cleanup.firstStart")) {
                    selectedHistory = nil
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
        .onAppear { optionsExpanded = !cleanup.configured }
        .interactiveDismissDisabled(cleanup.isBusy)
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
