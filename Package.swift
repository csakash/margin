// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Margin", targets: ["Margin"]),
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
            dependencies: ["MarginKit", "MarginCore"]
        ),
        .testTarget(
            name: "MarginCoreTests",
            dependencies: ["MarginCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
