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
        ),
    ],
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
        // ⚠️ DEPENDENCY POLICY — external (non-runbot-hq) packages MUST use revision: SHA.
        // branch: "main" is reserved for internal runbot-hq packages only (they are
        // owned by this org and changes are reviewed before landing on main).
        // External packages can push breaking changes to main at any time and would
        // silently break the next `swift package update` run in CI.
        //
        // TO UPDATE THESE DEPS:
        //   1. Run `swift package update` locally.
        //   2. Copy the new SHA from Package.resolved for the target package.
        //   3. Bump the revision: value here.
        //   4. Commit both Package.swift and Package.resolved changes together.
        //   ❌ Do NOT switch back to branch: "main" for either of these packages.
        .package(url: "https://github.com/LiYanan2004/MarkdownView", revision: "454625f199e5224109a275b8ef4d8a7202c704f2"),
        // swiftlang mirror required — must match MarkdownView's transitive dep URL exactly.
        // apple/swift-markdown and swiftlang/swift-markdown are treated as different SPM
        // identities even though they point to the same repo, causing an identity conflict
        // warning if the wrong mirror is used here.
        .package(url: "https://github.com/swiftlang/swift-markdown", revision: "27b7fc1a19068bcea3d2072db0ce86360d1400ed"),
    ],
    targets: [
        .target(
            name: "RunBotCore",
            dependencies: [
                .product(name: "GitHubClient", package: "GitHubClient"),
                .product(name: "AppUpdater", package: "AppUpdater"),
                .product(name: "Markdown", package: "swift-markdown"),
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
                // MarkdownView for rendering detected markdown in StepLogView (#2394).
                // swift-markdown (swiftlang mirror) arrives transitively via MarkdownView
                // and is also declared directly in RunBotCore for MarkdownDetector testability.
                .product(name: "MarkdownView", package: "MarkdownView"),
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
                .product(name: "GitHubClient", package: "GitHubClient")
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
    ]
)
