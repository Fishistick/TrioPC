// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrioPC",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TrioPC", targets: ["TrioPC"])],
    targets: [
        .target(name: "TrioCore"),
        .executableTarget(name: "TrioPC", dependencies: ["TrioCore"]),
        .testTarget(name: "TrioCoreTests", dependencies: ["TrioCore"])
    ]
)
