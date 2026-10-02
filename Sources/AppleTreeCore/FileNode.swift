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
    public let children: [FileNode]
    public let modified: Date?
    public var kind: FileKind { isDirectory ? .folder : FileKind.classify(url) }

    public init(url: URL, name: String? = nil, isDirectory: Bool, size: Int64,
                fileCount: Int? = nil, children: [FileNode] = [], modified: Date? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.modified = modified
        self.fileCount = fileCount ?? (isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1)
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
