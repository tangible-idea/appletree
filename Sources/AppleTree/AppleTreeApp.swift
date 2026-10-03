import SwiftUI
import AppKit
import AppleTreeCore

@main
struct AppleTreeApp: App {
    @StateObject private var store: AppStore
    @AppStorage(LanguagePreference.key) private var appLanguage = LanguagePreference.system

    init() {
        // Diagnostics pin the language through launch arguments instead.
        let isDiagnostic = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--snapshot")
        if !isDiagnostic { LanguagePreference.applyStored() }
        _store = StateObject(wrappedValue: AppStore())
    }

    var body: some Scene {
        WindowGroup("AppleTree") {
            ContentView().environmentObject(store)
                // Rebuilding the tree re-reads every string after a language change.
                .id(appLanguage)
                .preferredColorScheme(.light)
                .frame(minWidth: 1100, minHeight: 760)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let index = CommandLine.arguments.firstIndex(of: "--scan"), CommandLine.arguments.count > index + 1 {
                        store.scan(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                    #if DEBUG
                    AppDiagnostics.runIfRequested(store: store)
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 920)
        .commands {
            // Re-evaluated with the stored language so menu titles follow a change too.
            let _ = appLanguage
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("action.choose")) { store.chooseFolder() }.keyboardShortcut("o")
                Button(L10n.text("action.refresh")) { store.refresh() }.keyboardShortcut("r").disabled(store.isScanning)
            }
            CommandMenu(L10n.text("menu.navigate")) {
                Button(L10n.text("action.parent")) { store.goBack() }.keyboardShortcut("[", modifiers: .command)
                    .disabled(store.navigation.isEmpty)
                Button(L10n.text("action.reveal")) { if let node = store.selected { store.reveal(node) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(store.selected == nil || store.isDemo)
            }
        }

        Settings {
            SettingsView().environmentObject(store).id(appLanguage)
        }
    }
}
