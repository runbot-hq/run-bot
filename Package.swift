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
            // ⚠️ AI AGENT: This resources entry is required for Bundle.module to
            // exist and to find anything in Resources/Assets.xcassets (e.g.
            // StatusBarIcon) at runtime. Without it, there is no
            // RunBot_RunBot.bundle at all — see issue #2079.
            //
            // Note: `swift build` (the plain SwiftPM CLI, used by build.sh)
            // does NOT run actool to compile Assets.xcassets into Assets.car
            // the way Xcode does. It copies the .xcassets folder into the
            // resource bundle verbatim, as an uncompiled subdirectory tree
            // (confirmed via direct runtime inspection during the #2079
            // follow-up: Bundle.module's contents were just ["Assets.xcassets"]).
            //
            // This means NEITHER NSImage(named:) (searches Bundle.main's
            // compiled asset-catalog machinery) NOR
            // Bundle.module.image(forResource:) / path(forResource:ofType:)
            // (flat, bundle-root-only lookups) can find StatusBarIcon — both
            // expect either a compiled .car or a flat file at the bundle
            // root, and neither exists here. AppDelegate+StatusItem.swift
            // must load the PNG directly via its literal nested path
            // (Bundle.module.path(forResource:ofType:inDirectory:) pointed at
            // "Assets.xcassets/StatusBarIcon.imageset") + NSImage(contentsOfFile:).
            // Do NOT remove this resources entry, and do NOT "simplify" the
            // loading code back to NSImage(named:) or image(forResource:).
            resources: [
                .process("Resources")
            ],
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
