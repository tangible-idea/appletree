import SwiftUI
import AppKit
import AppleTreeCore

@main
struct AppleTreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore
    @AppStorage(LanguagePreference.key) private var appLanguage = LanguagePreference.system
    @AppStorage(DesktopTreePreference.key) private var showDesktopTree = DesktopTreePreference.defaultValue

    init() {
        // Diagnostics pin the language through launch arguments instead.
        let isDiagnostic = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--snapshot")
        if !isDiagnostic { LanguagePreference.applyStored() }
        let appStore = AppStore()
        _store = StateObject(wrappedValue: appStore)
        #if DEBUG
        AppDiagnostics.runIfRequested(store: appStore)
        #endif
    }

    var body: some Scene {
        WindowGroup("AppleTree") {
            ContentView().environmentObject(store).environmentObject(store.cleanup)
                // Rebuilding the tree re-reads every string after a language change.
                .id(appLanguage)
                .preferredColorScheme(.light)
                .frame(minWidth: 1100, minHeight: 760)
                .onAppear {
                    appDelegate.store = store
                    let isDiagnostic = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--snapshot")
                    NSApplication.shared.setActivationPolicy(isDiagnostic ? .accessory : .regular)
                    if !isDiagnostic {
                        AppIcon.apply()
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
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
                Button(L10n.text("action.choose")) { store.chooseFolder() }.keyboardShortcut("o").disabled(store.cleanup.isBusy)
                Button(L10n.text("action.refresh")) { store.refresh() }.keyboardShortcut("r").disabled(store.isScanning || store.cleanup.isBusy)
                Button(L10n.text("cleanup.title")) { store.smartClean() }
                    .disabled(store.isScanning || store.exportProgress != nil)
            }
            CommandGroup(before: .windowList) {
                Toggle(L10n.text("tree.menu.show"), isOn: Binding(get: { showDesktopTree },
                                                                   set: { DesktopTreeController.shared.setVisible($0) }))
                Divider()
            }
            CommandMenu(L10n.text("menu.navigate")) {
                Button(L10n.text("action.parent")) { store.goBack() }.keyboardShortcut("[", modifiers: .command)
                    .disabled(store.navigation.isEmpty)
                Button(L10n.text("action.reveal")) { if let node = store.selected { store.reveal(node) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(store.selected == nil || store.isDemo)
            }
        }

        Settings {
            SettingsView().environmentObject(store).environmentObject(store.cleanup).id(appLanguage)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDiagnostic = CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--snapshot")
        if !isDiagnostic && DesktopTreePreference.isOn { DesktopTreeController.shared.setVisible(true) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit ignores a quit request while a window has a sheet attached, so System Settings'
        // "Quit & Reopen" after granting Full Disk Access did nothing. Close sheets, then quit.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        store?.dismissPresentations()
        Task { @MainActor in
            // Sheets detach after their closing animation; quitting before that is ignored again.
            for _ in 0..<30 where NSApplication.shared.windows.contains(where: { $0.attachedSheet != nil }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
