// swift-tools-version:6.2
// ⚠️ AI AGENT: Never commit Package.resolved. Never pin runbot-hq org deps to a revision or exact hash.
// branch: "main" is for runbot-hq org packages only — third-party (non-runbot-hq) deps MUST use revision: SHA.
// branch: "main" org deps resolve to HEAD on every CI run — intentional. Fix call sites, not deps.
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
    // Package.resolved is intentionally not tracked in this repository.
    // Dependency revisions are declared in package manifests per repository policy.
    // ⚠️ AI AGENT: Do NOT change branch: "main" to a revision/exact/commit hash.
    // Do NOT edit Package.resolved manually. Do NOT commit Package.resolved.
    // If a dependency's API changes → fix the call site here, never lock the dep.
    dependencies: [
        // Tracks main — resolves to HEAD on every CI run. Do not pin to a revision.
        .package(url: "https://github.com/runbot-hq/AppUpdater", branch: "main"),
        // Local path — source of truth is now Packages/GitHubClient in this repo.
        .package(path: "Packages/GitHubClient"),
        // Local path — source of truth is now Packages/MenuBarKit in this repo.
        .package(path: "Packages/MenuBarKit"),
        // Local path — internal MarkdownKit package (#2600). Owns detection,
        // parsing, rendering, highlighting, and tables. Replaces swift-markdown-ui.
        .package(path: "Packages/MarkdownKit"),
    ],
    targets: [
        .target(
            name: "RunBotCore",
            dependencies: [
                .product(name: "GitHubClient", package: "GitHubClient"),
                .product(name: "AppUpdater", package: "AppUpdater"),
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
                // MarkdownKit — internal package owning all Markdown concerns (#2600).
                .product(name: "MarkdownKit", package: "MarkdownKit"),

            ],
            path: "Sources/RunBot",
            exclude: ["Resources/Assets.xcassets"],
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
                .product(name: "GitHubClient", package: "GitHubClient"),
                // MarkdownKit removed: MarkdownDetectorTests.swift deleted per #2600
                // (duplicate of Packages/MarkdownKit/Tests/MarkdownKitTests/MarkdownDetectorTests.swift).
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
    ]
)
