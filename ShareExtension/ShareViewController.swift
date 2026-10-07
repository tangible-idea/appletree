import AppKit
import UniformTypeIdentifiers

/// AppleTree in the Share menu: hands the shared files to the app, where the hedgehog suggests a folder.
/// The extension is sandboxed, so it only passes the paths along; the app does the moving.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let paths = SharedPaths()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL, url.isFileURL { paths.set(url.path, at: index) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            var components = URLComponents()
            components.scheme = "appletree"
            components.host = "organize"
            components.queryItems = paths.ordered.map { URLQueryItem(name: "path", value: $0) }
            if !paths.ordered.isEmpty, let url = components.url { NSWorkspace.shared.open(url) }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

/// Paths collected from the providers' callbacks, kept in the order the files were shared.
private final class SharedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var byIndex: [Int: String] = [:]

    func set(_ path: String, at index: Int) { lock.withLock { byIndex[index] = path } }
    var ordered: [String] { lock.withLock { byIndex.sorted { $0.key < $1.key }.map(\.value) } }
}
