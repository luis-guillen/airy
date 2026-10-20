// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Airy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
        .executable(name: "Airy", targets: ["Airy"]),
    ],
    targets: [
        .target(
            name: "DiskMapCore",
            path: "Sources/DiskMapCore",
            resources: [.process("Resources/catalog.json")]
        ),
        .executableTarget(
            name: "Airy",
            dependencies: ["DiskMapCore"],
            path: "Sources/Airy"
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
