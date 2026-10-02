// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleTree",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AppleTree", targets: ["AppleTree"])],
    targets: [
        .target(name: "AppleTreeCore", resources: [.process("Resources")]),
        .executableTarget(name: "AppleTree", dependencies: ["AppleTreeCore"]),
        .testTarget(name: "AppleTreeCoreTests", dependencies: ["AppleTreeCore"])
    ]
)
