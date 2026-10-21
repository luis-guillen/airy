// swift-tools-version: 6.3
import Foundation
import PackageDescription

// Con solo Command Line Tools, SwiftPM no localiza el plugin de macros de Swift Testing: se le indica a mano.
// Con Xcode (p. ej. en CI, que exporta AIRY_XCODE_TOOLCHAIN=1) no hace falta y rompería la compilación.
let testingPluginFlags: [SwiftSetting] = ProcessInfo.processInfo.environment["AIRY_XCODE_TOOLCHAIN"] == nil
    ? [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
    : []

let package = Package(
    name: "Airy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
        .executable(name: "Airy", targets: ["Airy"]),
        .executable(name: "airy-mcp", targets: ["AiryMCP"]),
    ],
    targets: [
        .target(
            name: "DiskMapCore",
            path: "Sources/DiskMapCore",
            resources: [.process("Resources/catalog.json"), .process("Resources/apps.json")]
        ),
        .executableTarget(
            name: "Airy",
            dependencies: ["DiskMapCore"],
            path: "Sources/Airy"
        ),
        .executableTarget(
            name: "AiryMCP",
            dependencies: ["DiskMapCore"],
            path: "Sources/AiryMCP"
        ),
        .testTarget(
            name: "DiskMapCoreTests",
            dependencies: ["DiskMapCore"],
            swiftSettings: testingPluginFlags
        ),
    ]
)
