// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VocalCord",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        .executableTarget(name: "VocalCord", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        // The MCP server the terminal agents launch; it relays to the running app.
        .executableTarget(name: "vocalcord-mcp"),
        .testTarget(name: "VocalCordTests", dependencies: ["VocalCord"]),
    ]
)
