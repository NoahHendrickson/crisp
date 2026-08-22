// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Crisp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Crisp",
            path: "Sources/Crisp",
            resources: [.copy("Resources")]
        )
    ]
)
