// swift-tools-version:6.0
import PackageDescription

let fast: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]

let package = Package(
    name: "Hakoniwa",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HakoniwaCore", targets: ["HakoniwaCore"]),
        .executable(name: "hakoniwa-cli", targets: ["hakoniwa-cli"]),
        .executable(name: "Hakoniwa", targets: ["Hakoniwa"]),
    ],
    targets: [
        .target(name: "HakoniwaCore", swiftSettings: fast),
        .executableTarget(name: "hakoniwa-cli", dependencies: ["HakoniwaCore"], swiftSettings: fast),
        .executableTarget(name: "Hakoniwa", dependencies: ["HakoniwaCore"], swiftSettings: fast),
        .testTarget(name: "HakoniwaCoreTests", dependencies: ["HakoniwaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
