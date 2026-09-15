// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThreadPocket",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ThreadPocket", targets: ["ThreadPocket"])
    ],
    targets: [
        .executableTarget(
            name: "ThreadPocket",
            path: "Sources/ThreadPocket",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
