// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "oscontrol",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "oscontrol", targets: ["oscontrol"]),
        .executable(name: "oscontrol-fixture", targets: ["oscontrol-fixture"]),
    ],
    targets: [
        .executableTarget(name: "oscontrol"),
        // Test-only AppKit window with known elements; its state is read by tests/e2e.
        .executableTarget(name: "oscontrol-fixture", path: "tests/fixture"),
    ]
)
