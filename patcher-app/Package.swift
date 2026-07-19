// swift-tools-version:5.9
// FineWine Patcher — built with SwiftPM + scripts/build-app.sh (no Xcode required).
import PackageDescription

let package = Package(
    name: "FineWinePatcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FineWinePatcher",
            path: "Sources/FineWinePatcher"
        )
    ]
)
