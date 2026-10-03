import Foundation

public enum FileKind: String, CaseIterable, Sendable {
    case folder, video, image, audio, archive, document, code, other

    public var title: String {
        switch self {
        case .folder: L10n.text("kind.folder")
        case .video: L10n.text("kind.video")
        case .image: L10n.text("kind.image")
        case .audio: L10n.text("kind.audio")
        case .archive: L10n.text("kind.archive")
        case .document: L10n.text("kind.document")
        case .code: L10n.text("kind.code")
        case .other: L10n.text("kind.other")
        }
    }

    public var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .video: "play.rectangle.fill"
        case .image: "photo.fill"
        case .audio: "waveform"
        case .archive: "archivebox.fill"
        case .document: "doc.text.fill"
        case .code: "curlybraces"
        case .other: "doc.fill"
        }
    }

    public static func classify(_ url: URL) -> FileKind {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": .video
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "raw", "psd", "svg": .image
        case "mp3", "wav", "flac", "m4a", "aiff", "aac": .audio
        case "zip", "dmg", "tar", "gz", "rar", "7z", "iso", "pkg": .archive
        case "pdf", "doc", "docx", "txt", "md", "pages", "xls", "xlsx", "csv", "key", "pptx": .document
        case "swift", "js", "ts", "tsx", "jsx", "py", "rs", "go", "json", "html", "css", "c", "h", "cpp": .code
        default: .other
        }
    }
}

public final class FileNode: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let children: [FileNode]
    public let modified: Date?
    public var kind: FileKind { isDirectory ? .folder : FileKind.classify(url) }

    public init(url: URL, name: String? = nil, isDirectory: Bool, size: Int64,
                fileCount: Int? = nil, directoryCount: Int? = nil, children: [FileNode] = [], modified: Date? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.modified = modified
        self.fileCount = fileCount ?? (isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1)
        self.directoryCount = directoryCount ?? (isDirectory ? children.filter { $0.isDirectory }.count : 0)
    }

    public func allFiles() -> [FileNode] {
        var result: [FileNode] = []
        var stack = [self]
        while let node = stack.popLast() {
            if node.isDirectory { stack.append(contentsOf: node.children) }
            else { result.append(node) }
        }
        return result
    }

    public func findNode(path: String) -> FileNode? {
        if self.url.path == path { return self }
        guard self.isDirectory else { return nil }
        for child in children {
            if path == child.url.path { return child }
            if path.hasPrefix(child.url.path.hasSuffix("/") ? child.url.path : child.url.path + "/") {
                if let found = child.findNode(path: path) { return found }
            }
        }
        return nil
    }
}

extension FileNode: Codable {
    enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, size, fileCount, directoryCount, children, modified
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let name = try container.decode(String.self, forKey: .name)
        let isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        let size = try container.decode(Int64.self, forKey: .size)
        let fileCount = try container.decode(Int.self, forKey: .fileCount)
        let directoryCount = try container.decodeIfPresent(Int.self, forKey: .directoryCount)
        let children = try container.decode([FileNode].self, forKey: .children)
        let modified = try container.decodeIfPresent(Date.self, forKey: .modified)
        self.init(url: url, name: name, isDirectory: isDirectory, size: size,
                  fileCount: fileCount, directoryCount: directoryCount,
                  children: children, modified: modified)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(name, forKey: .name)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(size, forKey: .size)
        try container.encode(fileCount, forKey: .fileCount)
        try container.encode(directoryCount, forKey: .directoryCount)
        try container.encode(children, forKey: .children)
        try container.encodeIfPresent(modified, forKey: .modified)
    }
}

public enum SizeText {
    public static func format(_ bytes: Int64) -> String {
        let value = max(0, Double(bytes))
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = value
        var index = 0
        while amount >= 1_000 && index < units.count - 1 { amount /= 1_000; index += 1 }
        return String(format: index == 0 || amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[index])
    }
}
