import Foundation
import os

public enum L10n {
    public static let supportedLanguages = ["en", "ko"]
    /// Each language's own name, shown in the language picker regardless of the UI language.
    public static let nativeNames = ["en": "English", "ko": "한국어"]
    // macOS includes any app-specific language preference in this ordered list.
    public static let systemLanguage = resolve(preferredLanguages: Locale.preferredLanguages)

    private static let chosen = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The language the UI is drawn in: the in-app choice if any, otherwise the Mac's preference.
    public static var language: String { chosen.withLock { $0 } ?? systemLanguage }

    /// Pass `nil` to follow the Mac's language again. Unsupported codes are ignored.
    public static func setLanguage(_ code: String?) {
        let value = code.flatMap { supportedLanguages.contains($0) ? $0 : nil }
        chosen.withLock { $0 = value }
    }

    public static func resolve(preferredLanguages: [String]) -> String {
        Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: preferredLanguages).first ?? "en"
    }

    static let resourceBundle: Bundle = {
        // Packaged .app builds keep SwiftPM resources in Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppleTree_AppleTreeCore.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: supportedLanguages.compactMap { code in
        guard let path = resourceBundle.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return (code, bundle)
    })

    public static func text(_ key: String, language: String = language) -> String {
        let bundle = bundles[language] ?? bundles["en"] ?? resourceBundle
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    public enum Count: String, CaseIterable {
        case files, items, subfolders, otherItems
    }

    public static func count(_ type: Count, _ value: Int, language: String = language) -> String {
        let key = "count.\(type.rawValue).\(value == 1 ? "one" : "other")"
        return String(format: text(key, language: language), value.formatted())
    }
}
