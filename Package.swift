// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(name: "CXattr"),
    .target(name: "AccCore", dependencies: [.target(name: "CXattr", condition: .when(platforms: [.linux]))]),
    .executableTarget(name: "acc", dependencies: ["AccCore"]),
    .testTarget(name: "AccCoreTests", dependencies: ["AccCore"]),
]
// The menu bar app is AppKit and SwiftUI; acc and its core also build on Linux.
#if os(macOS)
targets.append(.executableTarget(name: "Consolidatex", dependencies: ["AccCore"]))
#endif

let package = Package(
    name: "acc",
    platforms: [.macOS(.v13)],
    targets: targets
)
