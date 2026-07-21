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
        // ⚠️ TEMPORARY: pointing to fix branch for run-bot#2193 / AppUpdater#55 testing.
        // Revert to branch: "main" once AppUpdater#55 is merged.
        .package(url: "https://github.com/runbot-hq/AppUpdater", branch: "fix/sequential-relaunch-after-replace"),
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/GitHubClient", branch: "main"),
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        // Source lives at https://github.com/runbot-hq/MenuBarKit
        .package(url: "https://github.com/runbot-hq/MenuBarKit", branch: "main"),
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
            // ⚠️ AI AGENT: resources: [.process("Resources")] has been intentionally
            // REMOVED. Do NOT add it back without reading issue #2139 and #2136 first.
            //
            // Previously this entry caused SwiftPM to generate RunBot_RunBot.bundle
            // and resource_bundle_accessor.swift. The generated accessor probes
            // Bundle.main.bundleURL (the app root) for the bundle — but codesign
            // hard-rejects any directory at the app root other than Contents/.
            // This created an unsolvable three-way conflict between SwiftPM,
            // codesign, and the standard macOS .app layout.
            //
            // Fix: PNGs are now shipped as loose files in Contents/Resources/ by
            // build.sh and loaded via Bundle.main, which correctly resolves to
            // Contents/Resources/ for a packaged .app. No bundle, no accessor,
            // no conflict. See AppDelegate+StatusItem.swift and build.sh.
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
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
