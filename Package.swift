// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reprise",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Reprise",
            path: "Sources/PremiereMonitor"
        )
    ]
)
