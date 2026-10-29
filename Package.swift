// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ConvertMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ConvertMac", path: "Sources/ConvertMac")
    ]
)
