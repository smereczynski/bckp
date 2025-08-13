// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bckp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
        .executable(name: "bckp", targets: ["bckp-cli"]),
        .executable(name: "bckp-app", targets: ["bckp-app"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "BackupCore",
            dependencies: [],
            resources: []
        ),
        .executableTarget(
            name: "bckp-cli",
            dependencies: [
                "BackupCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "bckp-app",
            dependencies: ["BackupCore"],
            path: "Sources/bckp-app",
            resources: []
        ),
        .testTarget(
            name: "BackupCoreTests",
            dependencies: ["BackupCore"]
        ),
    ]
)
