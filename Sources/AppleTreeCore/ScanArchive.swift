import Foundation

/// Compact binary form of a scan for the on-disk index cache.
///
/// Nodes are written in pre-order with only their own name; full paths are rebuilt
/// from the parent while reading. This keeps a home-folder index roughly an order of
/// magnitude smaller than the keyed property list and far faster to load.
public enum ScanArchive {
    static let magic: [UInt8] = Array("ATIX".utf8)
    static let version: UInt32 = 1

    public enum Failure: Error { case badHeader, truncated }

    public static func encode(_ report: ScanReport) -> Data {
        var writer = Writer()
        writer.bytes.reserveCapacity(max(1024, (report.root.fileCount + report.root.directoryCount) * 40))
        writer.bytes.append(contentsOf: magic)
        writer.put(version)
        writer.put(report.scannedAt.timeIntervalSinceReferenceDate)
        writer.put(report.elapsed)
        writer.put(Int64(report.unreadableCount))
        writer.put(Int64(report.skippedLinks))
        writer.put(UInt32(report.unreadablePaths.count))
        for path in report.unreadablePaths { writer.put(path) }
        writer.put(report.root.url.path)

        func write(_ node: FileNode) {
            var flags: UInt8 = node.isDirectory ? 1 : 0
            if node.modified != nil { flags |= 2 }
            writer.put(node.name)
            writer.bytes.append(flags)
            writer.put(node.size)
            if let modified = node.modified { writer.put(modified.timeIntervalSinceReferenceDate) }
            if node.isDirectory {
                writer.put(UInt32(node.children.count))
                for child in node.children { write(child) }
            }
        }
        write(report.root)
        return Data(writer.bytes)
    }

    public static func decode(_ data: Data) throws -> ScanReport {
        try data.withUnsafeBytes { raw in
            var reader = Reader(raw: raw)
            guard raw.count >= 8, Array(raw.prefix(4)) == magic else { throw Failure.badHeader }
            reader.offset = 4
            guard try reader.get(UInt32.self) == version else { throw Failure.badHeader }
            let scannedAt = Date(timeIntervalSinceReferenceDate: try reader.get(Double.self))
            let elapsed = try reader.get(Double.self)
            let unreadableCount = Int(try reader.get(Int64.self))
            let skippedLinks = Int(try reader.get(Int64.self))
            let pathCount = Int(try reader.get(UInt32.self))
            var unreadablePaths: [String] = []
            for _ in 0..<pathCount { unreadablePaths.append(try reader.string()) }
            let rootPath = try reader.string()

            func read(parent: URL?) throws -> FileNode {
                let name = try reader.string()
                let flags = try reader.get(UInt8.self)
                let isDirectory = flags & 1 != 0
                let size = try reader.get(Int64.self)
                let modified = flags & 2 != 0 ? Date(timeIntervalSinceReferenceDate: try reader.get(Double.self)) : nil
                // Rebuilding from the parent avoids storing paths and never touches the file system.
                let nodeURL = parent?.appendingPathComponent(name, isDirectory: isDirectory)
                    ?? URL(fileURLWithPath: rootPath, isDirectory: true)
                guard isDirectory else {
                    return FileNode(url: nodeURL, name: name, isDirectory: false, size: size, fileCount: 1, directoryCount: 0, modified: modified)
                }
                let count = Int(try reader.get(UInt32.self))
                var children: [FileNode] = []
                children.reserveCapacity(count)
                for _ in 0..<count { children.append(try read(parent: nodeURL)) }
                return FileNode(url: nodeURL, name: name, isDirectory: true, size: size,
                                children: children, modified: modified)
            }
            let root = try read(parent: nil)
            return ScanReport(root: root, unreadableCount: unreadableCount, unreadablePaths: unreadablePaths,
                              skippedLinks: skippedLinks, elapsed: elapsed, scannedAt: scannedAt, isCached: true)
        }
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func put(_ value: Double) { put(value.bitPattern) }

        mutating func put(_ value: String) {
            let utf8 = value.utf8
            put(UInt32(utf8.count))
            bytes.append(contentsOf: utf8)
        }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var offset = 0

        mutating func get<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= raw.count else { throw Failure.truncated }
            let value = raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }

        mutating func get(_ type: Double.Type) throws -> Double {
            Double(bitPattern: try get(UInt64.self))
        }

        mutating func string() throws -> String {
            let length = Int(try get(UInt32.self))
            guard offset + length <= raw.count else { throw Failure.truncated }
            let value = String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length]), as: UTF8.self)
            offset += length
            return value
        }

    }
}
