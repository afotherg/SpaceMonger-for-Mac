// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceMonger",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceMonger for Mac", targets: ["SpaceMonger"])
    ],
    targets: [
        .executableTarget(
            name: "SpaceMonger",
            path: "Sources/SpaceMonger"
        )
    ]
)
