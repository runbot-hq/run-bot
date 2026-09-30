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
        // Organization-owned — tracks main. Source of truth is the runbot-hq/MarkdownKit repo.
        // Do not pin to a revision or exact hash.
        .package(url: "https://github.com/runbot-hq/MarkdownKit", branch: "main"),
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
            // GitHubClient is declared explicitly because the app target uses its
            // types directly, not only through RunBotCore: RunBotRuntime constructs
            // GitHubClient and OAuthCredentialController, RunBotApp reads
            // GitHubConstants for the OAuth callback, and roughly twenty UI files
            // import GitHubClient for GitHubAuthentication / GitHubStep / OAuthState.
            // SwiftPM does not re-export transitive dependencies, so those symbols
            // are only visible when GitHubClient is a direct dependency of this
            // target. AppUpdater is consumed transitively via RunBotCore and needs
            // no explicit entry.
            dependencies: [
                "RunBotCore",
                .product(name: "GitHubClient", package: "GitHubClient"),
                // MarkdownKit — organization-owned package (#2751). Tracks branch: "main".
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
            // Fix: Resources remain disabled for the SwiftPM executable target because release
            // packaging is owned by the generated Xcode app target. project.yml places
            // Assets.xcassets in the Copy Bundle Resources phase, and xcodebuild/actool
            // compiles it into Contents/Resources/Assets.car. The app loads StatusBarIcon
            // through NSImage(named:). Do not reintroduce Bundle.module or a SwiftPM
            // resource bundle; see issues #2139 and #2777.
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "RunBotCoreTests",
            dependencies: [
                "RunBotCore",
                .product(name: "GitHubClient", package: "GitHubClient"),
                // MarkdownDetector tests are owned by runbot-hq/MarkdownKit.
                // The duplicate RunBotCore test suite was removed under #2600.
            ],
            path: "Tests/RunBotCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
    ]
)
