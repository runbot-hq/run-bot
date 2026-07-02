// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "RunBot",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "RunBotCore",
            targets: ["RunBotCore"]
        ),
        .library(
            name: "AppUpdater",
            targets: ["AppUpdater"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "AppUpdater",
            dependencies: [],
            path: "Sources/AppUpdater",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "RunBotCore",
            dependencies: [
                "AppUpdater",
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Sources/RunBotCore",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .executableTarget(
            name: "RunBot",
            // AppUpdater is consumed transitively via RunBotCore — there is no
            // direct `import AppUpdater` in Sources/RunBot, so no explicit
            // dependency is needed here.
            dependencies: ["RunBotCore"],
            path: "Sources/RunBot",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "RunBotCoreTests",
            dependencies: [
                "RunBotCore",
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: [
                "AppUpdater"
            ],
            path: "Tests/AppUpdaterTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
