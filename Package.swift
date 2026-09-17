// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReBar",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ReBar")
    ]
)
