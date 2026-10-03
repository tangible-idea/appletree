import Foundation
import CoreGraphics
import Testing
@testable import AppleTreeCore

private func withFixture(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppleTreeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

@Test func scannerIncludesNestedAndHiddenFilesAndSortsBySize() throws {
    try withFixture { folder in
        let nested = folder.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: nested.appendingPathComponent("movie.mp4"))
        try Data(repeating: 2, count: 512).write(to: folder.appendingPathComponent("notes.txt"))
        try Data(repeating: 3, count: 10).write(to: folder.appendingPathComponent(".hidden"))
        let report = try DiskScanner.scan(folder)
        #expect(report.root.size == 1546)
        #expect(report.root.fileCount == 3)
        #expect(report.root.children.first?.name == "Nested")
        #expect(report.filesBySize.map(\.size) == [1024, 512, 10])
        #expect(report.unreadableCount == 0)
    }
}

@Test func scannerDoesNotFollowLinksOrLoops() throws {
    try withFixture { folder in
        try Data(repeating: 0, count: 64).write(to: folder.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("loop"), withDestinationURL: folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias"), withDestinationURL: folder.appendingPathComponent("real.txt"))
        let report = try DiskScanner.scan(folder)
        #expect(report.root.size == 64)
        #expect(report.root.fileCount == 1)
        #expect(report.skippedLinks == 2)
    }
}

@Test func emptyFolderAndZeroByteFileArePreserved() throws {
    try withFixture { folder in
        try Data().write(to: folder.appendingPathComponent("empty.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let report = try DiskScanner.scan(folder)
        #expect(report.root.size == 0)
        #expect(report.root.children.count == 2)
        #expect(report.root.fileCount == 1)
    }
}

@Test func rootFileIsRejected() throws {
    try withFixture { folder in
        let file = folder.appendingPathComponent("file.txt")
        try Data().write(to: file)
        #expect(throws: ScanFailure.self) { try DiskScanner.scan(file) }
    }
}

@Test func inaccessibleSubdirectoryProducesPartialReport() throws {
    try withFixture { folder in
        let restricted = folder.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        try Data(repeating: 0, count: 42).write(to: folder.appendingPathComponent("readable.txt"))
        let report = try DiskScanner.scan(folder)
        #expect(report.root.size == 42)
        #expect(report.unreadableCount == 1)
        #expect(report.unreadablePaths == [report.root.url.appendingPathComponent("restricted").path])
    }
}

@Test func cancelledScanDoesNotReturnPartialSuccess() async throws {
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try DiskScanner.scan(FileManager.default.temporaryDirectory)
    }
    do {
        _ = try await task.value
        Issue.record("Cancelled scan returned a result")
    } catch is CancellationError { }
}

@Test func treemapConservesAreaAndNeverOverlaps() {
    for weights: [Int64] in [[60, 25, 10, 5], [1], [10, 0, -1, 20], Array(repeating: 1, count: 99), [1_000_000, 4, 3, 2, 1]] {
        for bounds in [CGRect(x: 0, y: 0, width: 900, height: 280), CGRect(x: 5, y: 7, width: 200, height: 600)] {
            let tiles = Treemap.layout(weights: weights, in: bounds)
            let sum = weights.filter { $0 > 0 }.reduce(0, +)
            #expect(tiles.count == weights.filter { $0 > 0 }.count)
            let totalArea = tiles.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
            #expect(abs(totalArea - bounds.width * bounds.height) < 0.001)
            for tile in tiles {
                let expected = Double(weights[tile.index]) / Double(sum) * bounds.width * bounds.height
                #expect(abs(tile.rect.width * tile.rect.height - expected) < 0.001)
                #expect(tile.rect.minX >= bounds.minX - 0.001)
                #expect(tile.rect.minY >= bounds.minY - 0.001)
                #expect(tile.rect.maxX <= bounds.maxX + 0.001)
                #expect(tile.rect.maxY <= bounds.maxY + 0.001)
                for other in tiles where other.index != tile.index {
                    let intersection = tile.rect.intersection(other.rect)
                    #expect(intersection.isNull || intersection.width * intersection.height < 0.001)
                }
            }
        }
    }
}

@Test func treemapHandlesEmptyInput() {
    #expect(Treemap.layout(weights: [], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    #expect(Treemap.layout(weights: [0, 0], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    #expect(Treemap.layout(weights: [100], in: .zero).isEmpty)
}

@Test func sizesAndTypesAreReadable() {
    #expect(SizeText.format(0) == "0 B")
    #expect(SizeText.format(1_500) == "1.5 KB")
    #expect(SizeText.format(1_200_000_000) == "1.2 GB")
    #expect(FileKind.classify(URL(fileURLWithPath: "/test.MOV")) == .video)
    #expect(FileKind.classify(URL(fileURLWithPath: "/unknown")) == .other)
}

@Test func scanWithTargetBytesReportsTargetInProgress() throws {
    final class ProgressBox: @unchecked Sendable {
        var last: ScanProgress?
    }
    try withFixture { folder in
        try Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("test.bin"))
        let box = ProgressBox()
        let report = try DiskScanner.scan(folder, targetBytes: 500) { progress in
            box.last = progress
        }
        #expect(report.root.size == 100)
        #expect(box.last?.targetBytes == 500)
        #expect(box.last?.bytes == 100)
    }
}

@Test func fileNodeAndScanReportAreCodable() throws {
    try withFixture { folder in
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 50).write(to: sub.appendingPathComponent("file.txt"))

        let report = try DiskScanner.scan(folder)
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(report)
        let decoder = PropertyListDecoder()
        let decoded = try decoder.decode(ScanReport.self, from: data)

        #expect(decoded.root.size == report.root.size)
        #expect(decoded.root.fileCount == report.root.fileCount)
        #expect(decoded.isCached == true)
        #expect(decoded.root.findNode(path: sub.path) != nil)
    }
}

private func indexFixture() -> FileNode {
    let base = URL(fileURLWithPath: "/Fixture")
    let old = Date(timeIntervalSinceNow: -400 * 86_400)
    func file(_ path: String, _ size: Int64, _ modified: Date = Date()) -> FileNode {
        FileNode(url: base.appendingPathComponent(path), isDirectory: false, size: size, modified: modified)
    }
    func folder(_ path: String, _ children: [FileNode]) -> FileNode {
        let sorted = children.sorted { $0.size > $1.size }
        return FileNode(url: base.appendingPathComponent(path), isDirectory: true,
                        size: sorted.reduce(0) { $0 + $1.size }, children: sorted)
    }
    let project = folder("Project", [
        file("Project/package.json", 10),
        folder("Project/node_modules", [folder("Project/node_modules/left-pad/node_modules", [file("Project/node_modules/left-pad/node_modules/x.js", 5)]),
                                        file("Project/node_modules/a.js", 300)]),
        file("Project/release.jks", 4_000)
    ])
    let downloads = folder("Downloads", [
        file("Downloads/setup.dmg", 2_000_000_000, old),
        file("Downloads/스크린샷 2026-01-01.png".decomposedStringWithCanonicalMapping, 2_000_000),
        folder("Downloads/Empty", [])
    ])
    let copies = folder("Copies", [file("Copies/setup.dmg", 2_000_000_000), file("Copies/.env", 20)])
    let children = [project, downloads, copies].sorted { $0.size > $1.size }
    return FileNode(url: base, isDirectory: true, size: children.reduce(0) { $0 + $1.size }, children: children)
}

@Test func classifiesCertificatesByExtensionAndName() {
    #expect(FileKind.classify(name: "release.JKS") == .certificate)
    #expect(FileKind.classify(name: "AuthKey_ABC.p8") == .certificate)
    #expect(FileKind.classify(name: "id_ed25519") == .certificate)
    #expect(FileKind.classify(name: ".env.production") == .certificate)
    #expect(FileKind.classify(name: "model.gguf") == .model)
    #expect(FileKind.classify(name: "Xcode.xip") == .installer)
    #expect(FileKind.classify(name: ".gitignore") == .other)
}

@Test func searchIndexMatchesDecomposedKoreanNamesAndFolders() {
    let index = SearchIndex(root: indexFixture())
    #expect(index.search(SearchQuery(text: "스크린샷")).items.map(\.name).count == 1)
    #expect(index.search(SearchQuery(text: "NODE_mod")).items.map(\.name) == ["node_modules", "node_modules"])
    let result = index.search(SearchQuery(text: "setup"))
    #expect(result.totalCount == 2)
    #expect(result.totalSize == 4_000_000_000)
}

@Test func searchIndexFiltersByKindPresetAndScope() {
    let root = indexFixture()
    let index = SearchIndex(root: root)
    #expect(Set(index.search(SearchQuery(kinds: [.certificate])).items.map(\.name)) == ["release.jks", ".env"])
    #expect(index.search(SearchQuery(preset: .huge)).totalCount == 2)
    #expect(index.search(SearchQuery(preset: .stale)).items.map(\.name) == ["setup.dmg"])
    #expect(index.search(SearchQuery(preset: .oldDownloads)).totalCount == 1)
    #expect(index.search(SearchQuery(preset: .screenshots)).totalCount == 1)
    #expect(index.search(SearchQuery(preset: .duplicates)).totalCount == 2)
    // Nested caches are covered by their outermost folder.
    #expect(index.search(SearchQuery(preset: .devCaches)).items.map(\.name) == ["node_modules"])
    #expect(index.search(SearchQuery(preset: .emptyFolders)).items.map(\.name) == ["Empty"])
    let project = root.children.first { $0.name == "Project" }!
    let scoped = index.search(SearchQuery(), in: project)
    #expect(scoped.items.map(\.name) == ["release.jks", "a.js", "package.json", "x.js"])
}

@Test func searchIndexLimitsItemsButCountsEverything() {
    let base = URL(fileURLWithPath: "/Many")
    let files = (0..<30_000).map { FileNode(url: base.appendingPathComponent("file\($0).txt"), isDirectory: false, size: Int64($0)) }
    let root = FileNode(url: base, isDirectory: true, size: files.reduce(0) { $0 + $1.size }, children: files.reversed())
    let result = SearchIndex(root: root).search(SearchQuery(text: "file"), limit: 200)
    #expect(result.items.count == 200)
    #expect(result.totalCount == 30_000)
    #expect(result.items.first?.size == 29_999)
    #expect(zip(result.items, result.items.dropFirst()).allSatisfy { $0.size >= $1.size })
}

@Test func sunburstArcsFillTheirParentAngle() {
    let root = indexFixture()
    let arcs = Sunburst.layout(root: root)
    let ring = arcs.filter { $0.depth == 1 }
    #expect(abs(ring.reduce(0) { $0 + $1.span } - 2 * .pi) < 1e-9)
    #expect(ring.first?.node?.name == "Copies" || ring.first?.node?.name == "Downloads")
    for arc in arcs where arc.depth > 1 {
        #expect(arcs.contains { $0.depth == arc.depth - 1 && $0.start <= arc.start + 1e-9 && $0.end >= arc.end - 1e-9 })
    }
    // Tiny slices fold into one grey "smaller items" arc rather than disappearing.
    #expect(arcs.contains { $0.node == nil })
}

@Test func scanArchiveRoundTripsTreeAndMetadata() throws {
    try withFixture { folder in
        let sub = folder.appendingPathComponent("하위 폴더")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 50).write(to: sub.appendingPathComponent("사진.heic"))
        try Data(repeating: 1, count: 7).write(to: folder.appendingPathComponent("a.txt"))
        let report = try DiskScanner.scan(folder)
        let decoded = try ScanArchive.decode(ScanArchive.encode(report))
        #expect(decoded.isCached)
        #expect(decoded.root.url.path == report.root.url.path)
        #expect(decoded.root.size == 57 && decoded.root.fileCount == 2 && decoded.root.directoryCount == 1)
        #expect(decoded.scannedAt.timeIntervalSinceReferenceDate == report.scannedAt.timeIntervalSinceReferenceDate)
        let photo = decoded.root.findNode(path: sub.appendingPathComponent("사진.heic").path)
        #expect(photo?.size == 50 && photo?.modified != nil && photo?.kind == .image)
        #expect(throws: ScanArchive.Failure.self) { try ScanArchive.decode(Data("nope".utf8)) }
        #expect(throws: ScanArchive.Failure.self) { try ScanArchive.decode(ScanArchive.encode(report).prefix(40)) }
    }
}
