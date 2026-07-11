// swift-tools-version:6.2
// ⚠️ AI AGENT: Never commit Package.resolved. Never pin deps to a revision or exact hash.
// branch: "main" deps resolve to HEAD on every CI run — intentional. Fix call sites, not deps.
// These comments are deliberate guardrails — see AGENTS.md § Boundaries and README.md § External Dependencies.
import PackageDescription

let package = Package(
    name: "RunBot",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "RunBotCore",
            targets: ["RunBotCore"]
        )
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
            // GitHubClient is declared explicitly because AppDelegate+StoreSetup.swift
            // calls configureGHAPI / configureGHRaw / configureGHAPIPaginated / configureGHLogger
            // directly. SwiftPM does not re-export transitive dependencies, so the symbols
            // are only visible when GitHubClient is a direct dependency of this target.
            // AppUpdater is consumed transitively via RunBotCore and needs no explicit entry.
            dependencies: [
                "RunBotCore",
                .product(name: "GitHubClient", package: "GitHubClient")
            ],
            path: "Sources/RunBot",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        // ── Spike target ────────────────────────────────────────────────────────
        // Self-contained statusbar + NSOpenPanel behaviour test.
        // Zero RunBot dependencies — pure AppKit.
        // Verifies that NSOpenPanel comes to front when triggered from an
        // .accessory-policy menubar app using the activation-policy dance.
        // Run with: swift run StatusBarFilePickerSpike
        // Remove this target once spike-statusbar-filepicker-results.md is filled in.
        .executableTarget(
            name: "StatusBarFilePickerSpike",
            dependencies: [],
            path: "Sources/StatusBarFilePickerSpike",
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
