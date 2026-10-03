import Foundation

public enum DemoData {
    public static func make() -> FileNode {
        let base = URL(fileURLWithPath: "/Preview").appendingPathComponent(L10n.text("demo.root"))
        func file(_ name: String, _ gb: Double, at parent: URL) -> FileNode {
            FileNode(url: parent.appendingPathComponent(name), isDirectory: false,
                     size: Int64(gb * 1_000_000_000), modified: Date(timeIntervalSince1970: 1_775_000_000))
        }
        func folder(_ name: String, _ entries: [(String, Double)]) -> FileNode {
            let url = base.appendingPathComponent(name)
            let children = entries.map { file($0.0, $0.1, at: url) }.sorted { $0.size > $1.size }
            return FileNode(url: url, isDirectory: true, size: children.reduce(0) { $0 + $1.size },
                            children: children, modified: Date(timeIntervalSince1970: 1_775_000_000))
        }
        let nodes = [
            folder("Movies", [(L10n.text("demo.jeju"), 18.6), ("Studio recording.mp4", 12.4), (L10n.text("demo.summer"), 8.2), ("Archive footage.mp4", 3.6)]),
            folder("Downloads", [("macOS Installer.dmg", 12.1), ("Design resources.zip", 8.4), ("Backup 2025.zip", 6.8), ("Presentation.pdf", 1.3)]),
            folder("Pictures", [(L10n.text("demo.photos"), 10.8), ("Brand exploration.psd", 5.4), ("Film scans.tiff", 3.2)]),
            folder("Developer", [("Simulator runtime.dmg", 7.8), ("Project archive.zip", 3.6), ("dataset.json", 2.8)]),
            folder("Documents", [(L10n.text("demo.portfolio"), 3.1), (L10n.text("demo.research"), 2.2), ("Annual report.pdf", 1.5)]),
            folder("Music", [("Live session.wav", 2.6), ("Piano sketches.aiff", 1.3), ("Morning playlist.flac", 0.9)]),
            folder("Desktop", [("Screen recording.mov", 1.8), ("Moodboard.png", 0.5)])
        ].sorted { $0.size > $1.size }
        return FileNode(url: base, isDirectory: true, size: nodes.reduce(0) { $0 + $1.size }, children: nodes)
    }
}
