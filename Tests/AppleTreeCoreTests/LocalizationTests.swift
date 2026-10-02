import Foundation
import Testing
@testable import AppleTreeCore

@Test func languageFollowsMacPreferenceOrder() {
    #expect(L10n.resolve(preferredLanguages: ["ko-KR", "en-AU"]) == "ko")
    #expect(L10n.resolve(preferredLanguages: ["en-AU", "ko-KR"]) == "en")
    #expect(L10n.resolve(preferredLanguages: ["en-GB"]) == "en")
    #expect(L10n.resolve(preferredLanguages: ["ko"]) == "ko")
    #expect(L10n.resolve(preferredLanguages: ["fr-FR", "ko-KR"]) == "ko")
    #expect(L10n.resolve(preferredLanguages: ["ja-JP"]) == "en")
    #expect(L10n.resolve(preferredLanguages: []) == "en")
}

@Test func everyTranslationExistsAndPreservesPlaceholders() throws {
    func table(_ language: String) throws -> [String: String] {
        let path = try #require(L10n.resourceBundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
    let english = try table("en")
    let korean = try table("ko")
    #expect(english.count > 100)
    #expect(Set(english.keys) == Set(korean.keys))
    for (key, value) in english {
        let translated = try #require(korean[key])
        #expect(!value.isEmpty && !translated.isEmpty)
        #expect(value.components(separatedBy: "%@").count == translated.components(separatedBy: "%@").count)
        #expect(L10n.text(key, language: "en") == value)
        #expect(L10n.text(key, language: "ko") == translated)
        #expect(value.range(of: "[가-힣]", options: .regularExpression) == nil)
    }
}

@Test func translationsAndEnglishPluralFormsAreCorrect() {
    #expect(L10n.text("action.scan", language: "en") == "Scan folder")
    #expect(L10n.text("action.scan", language: "ko") == "폴더 분석")
    #expect(L10n.text("action.scan", language: "fr") == "Scan folder")
    #expect(L10n.count(.files, 0, language: "en") == "0 files")
    #expect(L10n.count(.files, 1, language: "en") == "1 file")
    #expect(L10n.count(.files, 2, language: "en") == "2 files")
    #expect(L10n.count(.files, 1, language: "ko") == "1개 파일")
    #expect(L10n.count(.subfolders, 1, language: "en") == "1 subfolder")
    #expect(L10n.count(.subfolders, 2, language: "en") == "2 subfolders")
    #expect(L10n.count(.items, 1, language: "en") == "1 item")
}
