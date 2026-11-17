// swift-tools-version:6.2
// FineWine — the menu bar app that manages Wine prefixes and launches Windows programs.
// Built with SwiftPM + scripts/build-app.sh (no Xcode project).
//
// FineWineCore holds everything that isn't UI (prefixes, runtimes, registry files, launch plans,
// shortcut apps) so it can be unit-tested and, later, shared with FineWine Patcher.
import PackageDescription

let package = Package(
    name: "FineWine",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "FineWineCore",
            path: "Sources/FineWineCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FineWine",
            dependencies: ["FineWineCore"],
            path: "Sources/FineWine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FineWineCoreTests",
            dependencies: ["FineWineCore"],
            path: "Tests/FineWineCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
