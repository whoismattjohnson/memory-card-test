// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryCardTest",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MemoryCardTest",
            path: "Sources/MemoryCardTest",
            swiftSettings: [
                // Use the Swift 5 language mode to keep the concurrency model
                // relaxed for this first version (avoids strict-sendable churn).
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
