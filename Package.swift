// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrioPC",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TrioCore", targets: ["TrioCore"]), .executable(name: "TrioPC", targets: ["TrioPC"])],
    targets: [
        .target(name: "TrioCore"),
        .target(name: "TrioHistoryPublisher", path: "integrations/trio-v1.0.2/publisher"),
        .executableTarget(name: "TrioPC", dependencies: ["TrioCore"]),
        .testTarget(name: "TrioCoreTests", dependencies: ["TrioCore", "TrioHistoryPublisher"])
    ]
)
