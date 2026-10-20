// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
        .executable(name: "DiskMap", targets: ["DiskMap"]),
    ],
    targets: [
        .target(
            name: "DiskMapCore",
            path: "Sources/DiskMapCore",
            resources: [.process("Resources/catalog.json")]
        ),
        .executableTarget(
            name: "DiskMap",
            dependencies: ["DiskMapCore"],
            path: "Sources/DiskMap"
        ),
        .testTarget(
            name: "DiskMapCoreTests",
            dependencies: ["DiskMapCore"],
            // Con solo Command Line Tools, SwiftPM no localiza el plugin de macros de Swift Testing.
            swiftSettings: [.unsafeFlags([
                "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
            ])]
        ),
    ]
)
