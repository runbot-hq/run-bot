// swift-tools-version:6.2
// ⚠️ AI AGENT: Never commit Package.resolved. Never pin deps to a revision or exact hash.
// branch: "main" deps resolve to HEAD on every CI run — intentional. Fix call sites, not pins.
// These comments are deliberate guardrails — see AGENTS.md § Boundaries and README.md § External Dependencies.
import PackageDescription

let package = Package(
    name: "RunBot",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "RunBotCore",
            targets: ["RunBotCore"]
        ),
        // ── MenuBarKit ─────────────────────────────────────────────────────────
        // Reusable NSPopover + SwiftUI sheet layer. Zero RunBot dependencies.
        // Will eventually move to its own package; lives here while the API
        // is being validated by RunBotSpike.
        .library(
            name: "MenuBarKit",
            targets: ["MenuBarKit"]
        ),
    ],
    // ⚠️ AI AGENT: Do NOT change branch: "main" to a revision/exact/commit hash.
    // Do NOT edit Package.resolved manually. Do NOT commit Package.resolved.
    // If a dependency's API changes → fix the call site here, never lock the dep.
    dependencies: [
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/AppUpdater", branch: "main"),
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/GitHubClient", branch: "main")
    ],
    targets: [
        .target(
            name: "RunBotCore",
            dependencies: [
                .product(name: "GitHubClient", package: "GitHubClient"),
                .product(name: "AppUpdater", package: "AppUpdater")
            ],
            path: "Sources/RunBotCore",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .executableTarget(
            name: "RunBot",
            dependencies: [
                "RunBotCore",
                .product(name: "GitHubClient", package: "GitHubClient")
            ],
            path: "Sources/RunBot",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        // ── MenuBarKit ─────────────────────────────────────────────────────────
        // Reusable popover/sheet layer. No RunBot or RunBotCore dependencies.
        .target(
            name: "MenuBarKit",
            dependencies: [],
            path: "Sources/MenuBarKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // ── Spike target ───────────────────────────────────────────────────────
        // Thin example app consuming MenuBarKit. Zero direct lifecycle code.
        // Run with: swift run RunBotSpike
        .executableTarget(
            name: "RunBotSpike",
            dependencies: ["MenuBarKit"],
            path: "Sources/RunBotSpike",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "RunBotCoreTests",
            dependencies: [
                "RunBotCore",
                .product(name: "GitHubClient", package: "GitHubClient")
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
    ]
)
