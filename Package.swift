// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Margin", targets: ["Margin"]),
    ],
    dependencies: [
        // The one dependency: in-app updates. Only the executable target links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Foundation + SQLite only. No AppKit, so it stays unit-testable.
        .target(
            name: "MarginCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Everything visual: panel, material, editor, drawer, capture.
        .target(
            name: "MarginKit",
            dependencies: ["MarginCore"]
        ),
        .executableTarget(
            name: "Margin",
            dependencies: ["MarginKit", "MarginCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "MarginCoreTests",
            dependencies: ["MarginCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
