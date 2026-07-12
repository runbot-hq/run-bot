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
    ],
    // ⚠️ AI AGENT: Do NOT change branch: "main" to a revision/exact/commit hash.
    // Do NOT edit Package.resolved manually. Do NOT commit Package.resolved.
    // If a dependency's API changes → fix the call site here, never lock the dep.
    dependencies: [
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/AppUpdater", branch: "main"),
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/GitHubClient", branch: "main"),
        // Local standalone package — real SPM boundary, own platforms constraint.
        // Source lives at Packages/MenuBarKit/. No network fetch required.
        .package(path: "Packages/MenuBarKit"),
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
            // calls configureGHAPI / configureGHRaw / configureGHAPIPaginated /
            // configureGHLogger directly. SwiftPM does not re-export transitive
            // dependencies, so the symbols are only visible when GitHubClient is a
            // direct dependency of this target. AppUpdater is consumed transitively
            // via RunBotCore and needs no explicit entry.
            dependencies: [
                "RunBotCore",
                .product(name: "GitHubClient", package: "GitHubClient"),
                // MenuBarKit declared here so RunBot can import it incrementally
                // during the #2027/#2028 migration alongside PopoverLifecycleCoordinator.
                // No RunBot source imports MenuBarKit yet — the dependency is additive
                // and costs nothing until the first import statement is written.
                .product(name: "MenuBarKit", package: "MenuBarKit"),
            ],
            path: "Sources/RunBot",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        // ── Spike target ───────────────────────────────────────────────────────────
        // Thin example app consuming MenuBarKit. Zero direct lifecycle code.
        // Run with: swift run RunBotSpike
        .executableTarget(
            name: "RunBotSpike",
            dependencies: [
                .product(name: "MenuBarKit", package: "MenuBarKit"),
            ],
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
