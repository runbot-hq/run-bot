// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunBot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RunBot", targets: ["RunBot"])
    ],
    dependencies: [
        .package(url: "https://github.com/runbot-hq/AppUpdater", branch: "main"),
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/GitHubClient", branch: "main"),
        // Temporarily tracking fix/arrow-center-drift for MBKPopoverController adoption.
        // See issue #2262. Switch back to branch: "main" once the PR is merged into MBK.
        // Revert tracked in #2275 — do not remove that issue until this line is back to main.
        // Source lives at https://github.com/runbot-hq/MenuBarKit
        .package(url: "https://github.com/runbot-hq/MenuBarKit", branch: "fix/arrow-center-drift"),
    ],
    targets: [
        .target(
            name: "RunBot",
            dependencies: [
                .product(name: "AppUpdater", package: "AppUpdater"),
                .product(name: "GitHubClient", package: "GitHubClient"),
                .product(name: "MenuBarKit", package: "MenuBarKit"),
                .product(name: "RunBotCore", package: "RunBotCore"),
            ]
        ),
        .target(
            name: "RunBotCore",
            dependencies: [
                .product(name: "GitHubClient", package: "GitHubClient"),
            ]
        ),
        .testTarget(
            name: "RunBotTests",
            dependencies: ["RunBotCore"]
        ),
    ]
)
