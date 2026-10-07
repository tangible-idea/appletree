import Foundation
import Testing
@testable import AppleTreeCore

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-suggest-\(UUID().uuidString)")
    let folders = ["Documents/Invoices/2026", "Documents/Taxes", "Documents/Code/app/.git", "Documents/Code/app/src",
                   "Documents/node_modules/pkg", "Downloads/unzipped-sdk", "Pictures/Trips", "Library/Caches", ".hidden/inner",
                   "google-cloud-sdk/lib"]
    for folder in folders {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    for file in ["Documents/Invoices/acme-march.pdf", "Documents/Invoices/2026/acme-may.pdf", "Downloads/invoice-june.pdf",
                 "Pictures/Trips/beach.jpg"] {
        try Data("x".utf8).write(to: home.appendingPathComponent(file))
    }
    return home
}

@Test func candidatesSkipHiddenToolAndCurrentFolders() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let dropped = home.appendingPathComponent("Downloads/invoice-june.pdf")
    let labels = FolderSuggester.candidates(home: home, excluding: dropped).map(\.label)

    #expect(labels.contains("~/Documents"))
    #expect(labels.contains("~/Documents/Invoices"))
    #expect(labels.contains("~/Documents/Invoices/2026"))
    #expect(labels.contains("~/Pictures/Trips"))
    // A repository is one destination; its insides are not offered.
    #expect(labels.contains("~/Documents/Code/app"))
    #expect(!labels.contains("~/Documents/Code/app/src"))
    #expect(!labels.contains { $0.contains("node_modules") || $0.contains("Library") || $0.contains(".hidden") || $0.contains(".git") })
    // The file is already in Downloads, whose subfolders and other home folders' insides aren't offered.
    #expect(!labels.contains("~/Downloads"))
    #expect(!labels.contains("~/Downloads/unzipped-sdk"))
    #expect(labels.contains("~/google-cloud-sdk"))
    #expect(!labels.contains("~/google-cloud-sdk/lib"))
    // The usual filing folders and their subfolders come before other home folders.
    #expect(labels.firstIndex(of: "~/Pictures/Trips")! < labels.firstIndex(of: "~/google-cloud-sdk")!)
    // Shallow folders come first, so a cap keeps the broad ones.
    #expect(labels.firstIndex(of: "~/Documents")! < labels.firstIndex(of: "~/Documents/Invoices")!)

    let invoices = try #require(FolderSuggester.candidates(home: home, excluding: dropped).first { $0.label == "~/Documents/Invoices" })
    #expect(Set(invoices.samples) == ["acme-march.pdf", "2026"])
}

@Test func aFolderIsNeverOfferedItselfOrItsSubfolders() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let labels = FolderSuggester.candidates(home: home, excluding: home.appendingPathComponent("Documents/Invoices")).map(\.label)
    #expect(!labels.contains("~/Documents/Invoices"))
    #expect(!labels.contains("~/Documents/Invoices/2026"))
    // Its parent is where it already is.
    #expect(!labels.contains("~/Documents"))
    #expect(labels.contains("~/Documents/Taxes"))
}

@Test func requestAsksOneChoiceOverFoldersWithoutFileContents() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let dropped = home.appendingPathComponent("Downloads/invoice-june.pdf")
    let candidates = FolderSuggester.candidates(home: home, excluding: dropped)
    let body = FolderSuggester.requestBody(for: DroppedFile(url: dropped), candidates: candidates)

    #expect(body["model"] as? String == "jev-latest")
    let state = try #require(body["state"] as? [String: Any])
    let file = try #require(state["file"] as? [String: Any])
    #expect(file["name"] as? String == "invoice-june.pdf")
    #expect(file["is_folder"] as? Bool == false)
    #expect(Set(file.keys).isSubset(of: ["name", "is_folder", "type", "size", "created", "modified"]))

    let questions = try #require(body["questions"] as? [String: Any])
    let folder = try #require(questions["folder"] as? [String: Any])
    #expect(folder["type"] as? String == "choice")
    let criteria = try #require(folder["criteria"] as? [String: Any])
    #expect(criteria.count == candidates.count + 1)
    #expect(criteria[FolderSuggester.noMatchOption] != nil)
    #expect((criteria["~/Documents/Taxes"] as? String) == "An empty folder.")
    #expect(JSONSerialization.isValidJSONObject(body))
}

@Test func suggestionsAreRankedAndDropUnlikelyAndUnknownOptions() throws {
    let candidates = ["~/Documents/Invoices", "~/Documents/Taxes", "~/Pictures"].map {
        FolderCandidate(url: URL(fileURLWithPath: "/Users/test/" + $0.dropFirst(2)), label: $0, samples: [])
    }
    let response = """
    {"model": "jev-1.13.0", "answers": {"folder": {"type": "choice", "choice": "~/Documents/Invoices",
      "probabilities": {"~/Documents/Invoices": 0.71, "~/Documents/Taxes": 0.2, "~/Pictures": 0.01,
                        "~/Unknown": 0.03, "none of these folders": 0.05}, "confidence": 0.6}},
     "usage": {"input_tokens": 900, "output_tokens": 40}}
    """
    let result = try FolderSuggester.suggestions(fromResponse: Data(response.utf8), candidates: candidates)
    #expect(result.ranked.map(\.folder.label) == ["~/Documents/Invoices", "~/Documents/Taxes"])
    #expect(result.ranked.first?.probability == 0.71)
    #expect(result.noMatch == 0.05)

    #expect(throws: TypeSafeError.invalidResponse) {
        try FolderSuggester.suggestions(fromResponse: Data("{\"answers\": {}}".utf8), candidates: candidates)
    }
}

@Test func movingNeverOverwritesAndUndoRestores() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTree-move-\(UUID().uuidString)")
    let source = root.appendingPathComponent("Downloads")
    let target = root.appendingPathComponent("Invoices")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = source.appendingPathComponent("bill.pdf")
    try Data("new".utf8).write(to: file)
    try Data("old".utf8).write(to: target.appendingPathComponent("bill.pdf"))

    let moved = try FileMover.move(file, into: target)
    #expect(moved.lastPathComponent == "bill 2.pdf")
    #expect(try Data(contentsOf: target.appendingPathComponent("bill.pdf")) == Data("old".utf8))
    #expect(!FileManager.default.fileExists(atPath: file.path))

    try FileMover.undo(movedTo: moved, originalLocation: file)
    #expect(try Data(contentsOf: file) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: moved.path))
}

@Test func bundledClientReadsInfoPlistOrEnvironment() {
    #expect(TypeSafeClient.bundled(.main, environment: [:]) == nil || Bundle.main.object(forInfoDictionaryKey: TypeSafeClient.infoPlistKey) != nil)
    #expect(TypeSafeClient.bundled(.main, environment: ["TYPESAFE_API_KEY": "  "]) == nil
        || Bundle.main.object(forInfoDictionaryKey: TypeSafeClient.infoPlistKey) != nil)
    #expect(TypeSafeClient.bundled(.main, environment: ["TYPESAFE_API_KEY": "ts-test"])?.apiKey != nil)
}
