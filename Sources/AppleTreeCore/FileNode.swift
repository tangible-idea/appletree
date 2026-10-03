import Foundation

public enum FileKind: String, CaseIterable, Sendable {
    case folder, video, image, audio, archive, document, code
    case certificate, installer, model, database, design, font, ebook, virtualMachine, log, other

    /// Kinds that can be picked as search filters (files only).
    public static let filterable: [FileKind] = [.image, .video, .audio, .document, .certificate, .installer, .archive,
                                                .model, .virtualMachine, .database, .design, .font, .ebook, .code, .log]

    public var title: String { L10n.text("kind.\(rawValue)") }

    public var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .video: "play.rectangle.fill"
        case .image: "photo.fill"
        case .audio: "waveform"
        case .archive: "archivebox.fill"
        case .document: "doc.text.fill"
        case .code: "curlybraces"
        case .certificate: "key.fill"
        case .installer: "shippingbox.fill"
        case .model: "brain"
        case .database: "cylinder.split.1x2.fill"
        case .design: "paintpalette.fill"
        case .font: "textformat"
        case .ebook: "book.closed.fill"
        case .virtualMachine: "desktopcomputer"
        case .log: "list.bullet.rectangle"
        case .other: "doc.fill"
        }
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.video, "mp4 mov mkv avi webm m4v wmv flv mpg mpeg 3gp mts m2ts")
        add(.image, "png jpg jpeg gif heic heif webp tiff tif bmp svg ico raw dng cr2 cr3 nef arw raf orf rw2 srw avif")
        add(.audio, "mp3 wav flac m4a aiff aif aac ogg opus wma caf")
        add(.archive, "zip tar gz tgz bz2 xz zst rar 7z cab")
        add(.installer, "dmg pkg mpkg iso ipa apk aab xip exe msi deb rpm appimage")
        add(.document, "pdf doc docx txt md rtf pages numbers xls xlsx csv tsv ppt pptx odt ods odp hwp hwpx")
        add(.code, "swift js ts tsx jsx py rs go json html css c h cpp hpp m mm java kt rb php sh yml yaml toml xml gradle")
        add(.certificate, "jks keystore bks p8 p12 pfx pem cer crt der key csr pub ppk mobileprovision provisionprofile p7b p7c gpg asc")
        add(.model, "gguf ggml safetensors ckpt pt pth onnx mlmodel mlpackage mlmodelc tflite h5 pb")
        add(.database, "sqlite sqlite3 db realm parquet sql mdb accdb duckdb")
        add(.design, "psd ai sketch fig xd afdesign afphoto blend indd")
        add(.font, "ttf otf woff woff2 ttc dfont")
        add(.ebook, "epub mobi azw azw3 ibooks")
        add(.virtualMachine, "vmdk vdi qcow2 vhd vhdx utm vmwarevm pvm hdd")
        add(.log, "log crash ips diag")
        return map
    }()

    /// Secret-bearing files that are usually recognised by name rather than extension.
    private static let certificateNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env", ".npmrc", ".netrc", ".pypirc", "credentials",
        "credentials.json", "googleservice-info.plist", "google-services.json", "service-account.json"
    ]

    public static func classify(_ url: URL) -> FileKind { classify(name: url.lastPathComponent) }

    public static func classify(name: String) -> FileKind {
        let lower = name.lowercased()
        if certificateNames.contains(lower) || lower.hasPrefix(".env.") { return .certificate }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return .other }
        return byExtension[String(lower[lower.index(after: dot)...])] ?? .other
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
    public var kind: FileKind { isDirectory ? .folder : FileKind.classify(name: name) }

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
