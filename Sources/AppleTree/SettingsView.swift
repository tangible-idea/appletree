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
        Form {
            Picker(L10n.text("settings.language"), selection: language) {
                Text(L10n.format("settings.language.system", L10n.nativeNames[L10n.systemLanguage] ?? L10n.systemLanguage))
                    .tag(LanguagePreference.system)
                ForEach(L10n.supportedLanguages, id: \.self) { code in
                    Text(L10n.nativeNames[code] ?? code).tag(code)
                }
            }
            .pickerStyle(.radioGroup)
            Text(L10n.text("settings.language.note"))
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Divider().padding(.vertical, 10)
            Toggle(L10n.text("settings.dates.show"), isOn: $showModificationDates)
            Text(L10n.text("settings.dates.note"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
        .navigationTitle(L10n.text("settings.title"))
    }
}
