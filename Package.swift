// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "StorageManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StorageManager", targets: ["StorageManager"]),
    ],
    targets: [
        // Scanning, safety rules and the recovery vault. No UI code lives here so it can be tested headlessly.
        .target(name: "StorageCore", path: "Sources/StorageCore"),
        // The SwiftUI desktop app.
        .executableTarget(name: "StorageManager", dependencies: ["StorageCore"], path: "Sources/StorageManager"),
        // `swift run SafetyChecks` — exercises the safety guard and the vault without touching real files.
        .executableTarget(name: "SafetyChecks", dependencies: ["StorageCore"], path: "Sources/SafetyChecks"),
    ]
)
