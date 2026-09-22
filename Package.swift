// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArranqueLimpio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ArranqueLimpio", path: "Sources/ArranqueLimpio")
    ]
)
