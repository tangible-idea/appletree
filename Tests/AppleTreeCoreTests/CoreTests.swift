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
