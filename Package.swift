// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskSweep",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DiskSweep",
            path: "Sources/DiskSweep"
        )
    ]
)
