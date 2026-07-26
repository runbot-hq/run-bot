// swift-tools-version:6.2
// MenuBarKit — standalone package, consumed via SPM URL branch: "main".
// Zero dependencies on RunBot or RunBotCore.
import PackageDescription

let package = Package(
    name: "MenuBarKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "MenuBarKit",
            targets: ["MenuBarKit"]
            // MenuBarKitExample is intentionally NOT listed here.
            // It is an internal example app for CI validation only.
            // Consumers of this package via SPM URL will never see it.
        )
    ],
    targets: [
        .target(
            name: "MenuBarKit",
            dependencies: [],
            path: "Sources/MenuBarKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        // ── Example app ──────────────────────────────────────────────────────────
        // Thin consumer of MenuBarKit. Validates the public API compiles and
        // exercises all three scenarios (sheet, file picker, alert) on every CI run.
        // Not in products — invisible to downstream SPM consumers.
        // Run locally with: swift run MenuBarKitExample
        .executableTarget(
            name: "MenuBarKitExample",
            dependencies: [.target(name: "MenuBarKit")],
            path: "Sources/MenuBarKitExample",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "MenuBarKitTests",
            dependencies: ["MenuBarKit"],
            path: "Tests/MenuBarKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
