import SwiftUI
import AppleTreeCore

/// Stored language choice: "system" follows the Mac, otherwise a supported language code.
enum LanguagePreference {
    static let key = "appLanguage"
    static let system = "system"

    /// Applies the stored choice before any view reads a string.
    static func applyStored() {
        let stored = UserDefaults.standard.string(forKey: key) ?? system
        L10n.setLanguage(stored == system ? nil : stored)
    }
}

enum FileListPreference {
    static let showModificationDatesKey = "showModificationDates"
    static let showModificationDatesByDefault = true
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(LanguagePreference.key) private var appLanguage = LanguagePreference.system
    @AppStorage(FileListPreference.showModificationDatesKey)
    private var showModificationDates = FileListPreference.showModificationDatesByDefault

    private var language: Binding<String> {
        Binding(get: { appLanguage }, set: { code in
            // Switch the strings first: the stored value change is what redraws the windows.
            L10n.setLanguage(code == LanguagePreference.system ? nil : code)
            appLanguage = code
            store.languageDidChange()
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SettingsSection(symbol: "globe", title: L10n.text("settings.language"),
                                note: L10n.text("settings.language.note")) {
                    VStack(spacing: 0) {
                        languageRow(LanguagePreference.system,
                                    title: L10n.format("settings.language.system",
                                                       L10n.nativeNames[L10n.systemLanguage] ?? L10n.systemLanguage))
                        ForEach(L10n.supportedLanguages, id: \.self) { code in
                            Divider().overlay(Theme.line)
                            languageRow(code, title: L10n.nativeNames[code] ?? code)
                        }
                    }
                }
                SettingsSection(symbol: "list.bullet.rectangle", title: L10n.text("settings.section.display"),
                                note: L10n.text("settings.dates.note")) {
                    Toggle(isOn: $showModificationDates) {
                        Text(L10n.text("settings.dates.show")).font(.system(size: 13))
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
                SettingsSection(symbol: "sparkles", title: L10n.text("cleanup.scope.title")) {
                    CleanupOptions().padding(14)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 640)
        .foregroundStyle(Theme.ink).background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.light)
        .navigationTitle(L10n.text("settings.title"))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("settings.title")).font(.system(size: 20, weight: .semibold))
                Text("AppleTree").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private func languageRow(_ code: String, title: String) -> some View {
        Button { language.wrappedValue = code } label: {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if appLanguage == code {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A titled white card, matching the app's quiet palette.
private struct SettingsSection<Content: View>: View {
    let symbol: String
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.system(size: 12, weight: .semibold))
            } icon: {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.leading, 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}
