// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VocalCord",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "VocalCord"),
        .testTarget(name: "VocalCordTests", dependencies: ["VocalCord"]),
    ]
)
