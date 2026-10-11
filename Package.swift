// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Monotask",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Monotask",
            path: "Sources/Monotask",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
