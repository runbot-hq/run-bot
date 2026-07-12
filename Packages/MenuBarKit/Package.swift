// swift-tools-version:6.2
// MenuBarKit — local standalone package.
// Consumed by the root package via .package(path: "Packages/MenuBarKit").
// Zero dependencies on RunBot or RunBotCore.
import PackageDescription

let package = Package(
    name: "MenuBarKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "MenuBarKit",
            targets: ["MenuBarKit"]
        ),
    ],
    targets: [
        .target(
            name: "MenuBarKit",
            dependencies: [],
            path: "Sources/MenuBarKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
