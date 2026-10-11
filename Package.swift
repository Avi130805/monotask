// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Next",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Next",
            path: "Sources/Next",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
