// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWithObsidian",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "OpenWithObsidianKit", targets: ["OpenWithObsidianKit"]),
        .executable(name: "OpenWithObsidian", targets: ["OpenWithObsidianApp"]),
    ],
    targets: [
        .target(name: "OpenWithObsidianKit"),
        .executableTarget(
            name: "OpenWithObsidianApp",
            dependencies: ["OpenWithObsidianKit"]
        ),
        .testTarget(
            name: "OpenWithObsidianKitTests",
            dependencies: ["OpenWithObsidianKit"]
        ),
    ]
)
