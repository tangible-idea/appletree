import Foundation

public enum L10n {
    public static let supportedLanguages = ["en", "ko"]
    // macOS includes any app-specific language preference in this ordered list.
    public static let language = resolve(preferredLanguages: Locale.preferredLanguages)

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
