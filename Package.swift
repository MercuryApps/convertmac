// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoAudioConverter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VideoAudioConverter", path: "Sources/VideoAudioConverter")
    ]
)
