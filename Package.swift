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
            name: "GitHubClient",
            targets: ["GitHubClient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/runbot-hq/AppUpdater", branch: "main")
    ],
    targets: [
        .target(
            name: "GitHubClient",
            dependencies: [],
            path: "Sources/GitHubClient",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "RunBotCore",
            dependencies: [
                "GitHubClient",
                .product(name: "AppUpdater", package: "AppUpdater"),
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
                "GitHubClient",
                .product(name: "Collections", package: "swift-collections")
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "GitHubClientTests",
            dependencies: ["GitHubClient"],
            path: "Tests/GitHubClientTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
    ]
)
