// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimMirror",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SimMirror",
            path: "Sources/SimMirror"
        )
    ]
)
