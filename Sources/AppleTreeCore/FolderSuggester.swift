import Foundation
import UniformTypeIdentifiers

/// A folder the dropped file could be filed into, described by its path and a few of its items.
public struct FolderCandidate: Sendable, Hashable {
    public let url: URL
    /// Home-relative path such as `~/Documents/Invoices`; also the Choice option sent to Jev.
    public let label: String
    public let samples: [String]

    public init(url: URL, label: String, samples: [String]) {
        self.url = url
        self.label = label
        self.samples = samples
    }

    public var name: String { url.lastPathComponent }
}

public struct FolderSuggestion: Sendable, Hashable {
    public let folder: FolderCandidate
    public let probability: Double
}

public struct FolderSuggestions: Sendable {
    public let ranked: [FolderSuggestion]
    /// Probability Jev gave to "none of the listed folders fits".
    public let noMatch: Double
}

/// What Jev sees about the dropped file: its name and metadata, never its contents.
public struct DroppedFile: Sendable, Equatable {
    public let url: URL
    public let isFolder: Bool
    public let kind: String
    public let size: Int64
    public let created: Date?
    public let modified: Date?

    public init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey,
                                                       .fileSizeKey, .creationDateKey, .contentModificationDateKey])
        self.url = url
        isFolder = values?.isDirectory == true && values?.isPackage != true
        // The type identifier (e.g. com.adobe.pdf). Localized descriptions come from Launch Services,
        // which stalled when several threads asked at once.
        kind = values?.contentType?.identifier ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? ""
        size = Int64(values?.fileSize ?? 0)
        created = values?.creationDate
        modified = values?.contentModificationDate
    }
}

public enum FolderSuggester {
    public static let noMatchOption = "none of these folders"
    /// Choice questions allow 255 options; this leaves room for the no-match option and keeps requests small.
    public static let maxCandidates = 200
    static let samplesPerFolder = 4
    /// Where people file things; these are offered two levels deep, before anything else.
    static let filingRoots = ["Documents", "Desktop", "Pictures", "Movies", "Music"]
    static let filingDepth = 2
    /// Folders that are tool output or app internals, never a place a person files things.
    static let skippedNames: Set<String> = ["Library", "Applications", "Public", "node_modules", "build", "DerivedData",
                                            "Pods", "vendor", "dist", "target", "venv", "__pycache__"]

    /// Folders under home, best filing places first, leaving out where the file already is.
    /// The usual filing folders are offered with their subfolders. Downloads and other home folders
    /// (often unpacked archives, SDKs and projects) are offered only at the top.
    public static func candidates(home: URL, excluding file: URL, fileManager: FileManager = .default) -> [FolderCandidate] {
        let home = home.standardizedFileURL
        let file = file.standardizedFileURL
        let currentParent = file.deletingLastPathComponent().path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .contentModificationDateKey]
        let topLevel = (visibleChildren(of: home, keys: keys, fileManager: fileManager) ?? []).filter { isFilingFolder($0) }
        let filing = filingRoots.compactMap { name in topLevel.first { $0.lastPathComponent == name } }
        let others = topLevel.filter { !filingRoots.contains($0.lastPathComponent) }
        var result: [FolderCandidate] = []
        // Breadth-first within each group, so a cap keeps the broad folders.
        for (roots, maxDepth) in [(filing, filingDepth), (others, 0)] {
            var queue: [(url: URL, depth: Int)] = roots.map { ($0, 0) }
            while !queue.isEmpty, result.count < maxCandidates {
                let (listed, depth) = queue.removeFirst()
                // Listings can spell temporary paths as /private/var while the dropped URL says /var.
                let folder = listed.standardizedFileURL
                let path = folder.path
                // A folder can't be moved into itself or its own subfolders.
                if path == file.path || path.hasPrefix(file.path + "/") { continue }
                guard let children = visibleChildren(of: folder, keys: keys, fileManager: fileManager) else { continue }
                if path != currentParent {
                    let newest = children.sorted { modified($0) > modified($1) }
                    result.append(FolderCandidate(url: folder, label: label(for: folder, home: home),
                                                  samples: newest.prefix(samplesPerFolder).map { shortName($0.lastPathComponent) }))
                }
                // A code repository is one place to file things, not a tree of destinations.
                let isRepository = children.contains { $0.lastPathComponent == ".git" }
                if depth < maxDepth, !isRepository {
                    queue += children.filter { isFilingFolder($0) }.map { ($0, depth + 1) }
                }
            }
        }
        return result
    }

    /// The System One request: the file as state, and one Choice over the candidate folders.
    public static func requestBody(for file: DroppedFile, candidates: [FolderCandidate], model: String = "jev-latest") -> [String: Any] {
        var fileState: [String: Any] = [
            "name": file.url.lastPathComponent,
            "is_folder": file.isFolder,
            "type": file.kind,
        ]
        if !file.isFolder { fileState["size"] = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withFullDate]
        if let created = file.created { fileState["created"] = dates.string(from: created) }
        if let modified = file.modified { fileState["modified"] = dates.string(from: modified) }

        var criteria: [String: Any] = [:]
        for candidate in candidates {
            criteria[candidate.label] = candidate.samples.isEmpty
                ? "An empty folder."
                : "Holds items such as: " + candidate.samples.joined(separator: ", ")
        }
        criteria[noMatchOption] = "None of the listed folders is a sensible place to keep this file."

        return [
            "model": model,
            "state": ["file": fileState],
            "questions": [
                "folder": [
                    "type": "choice",
                    "instructions": [
                        "question": "A person wants to tidy up their Mac. Which folder is the best place to keep the file described in `file`?",
                        "guidance": [
                            "Judge what the file is from its name, type and dates.",
                            "Judge what each folder is for from its path and the items it holds.",
                            "Prefer the most specific folder that clearly fits over a broad parent folder.",
                        ],
                    ],
                    "criteria": criteria,
                ] as [String: Any],
            ],
        ]
    }

    /// Ranks the folders by Jev's probabilities, best first.
    public static func suggestions(fromResponse data: Data, candidates: [FolderCandidate], limit: Int = 3,
                                   minimumProbability: Double = 0.03) throws -> FolderSuggestions {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let folder = answers["folder"] as? [String: Any],
              let probabilities = folder["probabilities"] as? [String: Any] else {
            throw TypeSafeError.invalidResponse
        }
        let byLabel = Dictionary(candidates.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = probabilities.compactMap { label, value -> FolderSuggestion? in
            guard let candidate = byLabel[label], let probability = (value as? NSNumber)?.doubleValue,
                  probability >= minimumProbability else { return nil }
            return FolderSuggestion(folder: candidate, probability: probability)
        }
        .sorted { $0.probability > $1.probability }
        let noMatch = (probabilities[noMatchOption] as? NSNumber)?.doubleValue ?? 0
        return FolderSuggestions(ranked: Array(ranked.prefix(limit)), noMatch: noMatch)
    }

    static func label(for folder: URL, home: URL) -> String {
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    private static func visibleChildren(of folder: URL, keys: [URLResourceKey], fileManager: FileManager) -> [URL]? {
        // Hidden items are filtered here, except .git, which marks a repository.
        guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        return items.filter { item in
            item.lastPathComponent == ".git"
                || ((try? item.resourceValues(forKeys: [.isHiddenKey]))?.isHidden != true && !item.lastPathComponent.hasPrefix("."))
        }
    }

    private static func isFilingFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
            && !name.hasPrefix(".") && !skippedNames.contains(name)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func shortName(_ name: String) -> String {
        name.count > 40 ? String(name.prefix(37)) + "…" : name
    }
}

/// Moving a file into a suggested folder without overwriting anything, and putting it back.
public enum FileMover {
    /// Moves `file` into `folder`, adding " 2", " 3"… to the name if it is taken. Returns the new location.
    public static func move(_ file: URL, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        let destination = availableURL(for: file.lastPathComponent, in: folder, fileManager: fileManager)
        try fileManager.moveItem(at: file, to: destination)
        return destination
    }

    /// Returns the file to where it was. Fails rather than overwrite something new in its old place.
    public static func undo(movedTo current: URL, originalLocation: URL, fileManager: FileManager = .default) throws {
        try fileManager.moveItem(at: current, to: originalLocation)
    }

    static func availableURL(for name: String, in folder: URL, fileManager: FileManager) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for number in 2... {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let url = folder.appendingPathComponent(numbered)
            if !fileManager.fileExists(atPath: url.path) { return url }
        }
        return candidate
    }
}
