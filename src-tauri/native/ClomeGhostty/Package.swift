// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClomeGhostty",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClomeGhostty", type: .static, targets: ["ClomeGhostty"])
    ],
    targets: [
        .systemLibrary(name: "CGhostty", path: "Sources/CGhostty"),
        .target(
            name: "ClomeGhostty",
            dependencies: ["CGhostty"]
        )
    ]
)
