// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "acc",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AccCore"),
        .executableTarget(name: "acc", dependencies: ["AccCore"]),
        .executableTarget(name: "Consolidatex", dependencies: ["AccCore"]),
        .testTarget(name: "AccCoreTests", dependencies: ["AccCore"]),
    ]
)
