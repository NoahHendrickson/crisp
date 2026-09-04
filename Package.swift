// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Crisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Crisp", targets: ["Crisp"]),
        .executable(name: "crispctl", targets: ["CrispControl"]),
        .executable(name: "crisp-mcp", targets: ["CrispMCP"]),
    ],
    targets: [
        .target(
            name: "CrispAutomationProtocol",
            path: "Sources/CrispAutomationProtocol"
        ),
        .executableTarget(
            name: "Crisp",
            dependencies: ["CrispAutomationProtocol"],
            path: "Sources/Crisp",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "CrispControl",
            dependencies: ["CrispAutomationProtocol"],
            path: "Sources/CrispControl"
        ),
        .executableTarget(
            name: "CrispMCP",
            dependencies: ["CrispAutomationProtocol"],
            path: "Sources/CrispMCP"
        ),
        .testTarget(
            name: "CrispAutomationProtocolTests",
            dependencies: ["CrispAutomationProtocol"]
        ),
    ]
)
