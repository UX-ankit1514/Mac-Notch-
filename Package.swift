// swift-tools-version: 6.2
import PackageDescription

let approachable: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "NotchCompanion",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NotchCompanion", targets: ["NotchCompanion"]),
        .executable(name: "notch-hook", targets: ["NotchHook"]),
        .library(name: "NotchCore", targets: ["NotchCore"]),
    ],
    targets: [
        // Event model, connectors, IPC, notification logic, storage, installer.
        // A library: nonisolated by default so the CLI and the app both use it.
        .target(name: "NotchCore", swiftSettings: approachable),

        // The tiny helper agent hooks call. Always exits 0, never prints a decision.
        .executableTarget(
            name: "NotchHook",
            dependencies: ["NotchCore"],
            path: "Sources/notch-hook",
            swiftSettings: approachable),

        // The menu-bar app: notch overlay, character, screens.
        .executableTarget(
            name: "NotchCompanion",
            dependencies: ["NotchCore"],
            swiftSettings: approachable + [.defaultIsolation(MainActor.self)]),

        .testTarget(
            name: "NotchCoreTests",
            dependencies: ["NotchCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: approachable),
    ]
)
