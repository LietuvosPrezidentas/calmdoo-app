// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Booster",
    platforms: [.macOS(.v15)],
    targets: [
        // Sound engine: process list, taps, gain and limiter. No UI.
        .target(name: "BoosterCore"),
        // The menu bar app.
        .executableTarget(name: "Booster", dependencies: ["BoosterCore"]),
        .testTarget(name: "BoosterCoreTests", dependencies: ["BoosterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
