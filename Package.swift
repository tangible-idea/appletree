// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleTree",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AppleTree", targets: ["AppleTree"])],
    targets: [
        .target(name: "AppleTreeCore", resources: [.process("Resources")]),
        .executableTarget(name: "AppleTree", dependencies: ["AppleTreeCore"],
                          exclude: ["Resources/Assets.xcassets"], resources: [.copy("Resources/AppleTree.icns")]),
        .testTarget(name: "AppleTreeCoreTests", dependencies: ["AppleTreeCore"])
    ]
)
