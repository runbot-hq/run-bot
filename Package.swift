// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GitHubClient",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "EnvTokenKit",
            targets: ["EnvTokenKit"]
        ),
        .library(
            name: "OAuthTokenKit",
            targets: ["OAuthTokenKit"]
        ),
        .library(
            name: "GitHubClient",
            targets: ["GitHubClient"]
        )
    ],
    targets: [
        .target(
            name: "EnvTokenKit",
            path: "Sources/EnvTokenKit",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "OAuthTokenKit",
            path: "Sources/OAuthTokenKit",
            // No dependency on EnvTokenKit — OAuthTokenKit and EnvTokenKit are peer targets,
            // not a stack. Each owns one resolution mechanism (Keychain/OAuth vs.
            // env-var/login-shell) and neither needs the other's types. GitHubClient is the
            // only target that depends on both, wiring them together via TokenCache.
            // See TokenCache Boundary Rule in #74.
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .target(
            name: "GitHubClient",
            dependencies: ["EnvTokenKit", "OAuthTokenKit"],
            path: "Sources/GitHubClient",
            exclude: ["README.md"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "EnvTokenKitTests",
            dependencies: ["EnvTokenKit"],
            path: "Tests/EnvTokenKitTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "OAuthTokenKitTests",
            dependencies: ["OAuthTokenKit"],
            path: "Tests/OAuthTokenKitTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "GitHubClientTests",
            // EnvTokenKit is listed here in addition to GitHubClient.
            // This deviates from the spec (#73) which shows ["GitHubClient"] only.
            //
            // ## Why the deviation is intentional
            // GitHubClientTests constructs StubEnvTokenProvider directly — an EnvTokenKit
            // concrete type — to inject it into TokenCache via the public
            // `init(tokenStore:envProvider:logger:)` seam. This lets the tests exercise
            // TokenCache's env-provider path without going through GitHubClient's
            // production init or touching the live process environment.
            //
            // The alternative — defining a parallel stub inside GitHubClientTests itself
            // (conforming to `any EnvTokenProviding`) — would duplicate the stub for no
            // gain and would prevent tests from using StubEnvTokenProvider's callCount
            // and invalidateCalled spy properties, which are specific to the shared type.
            //
            // Consequence: GitHubClientTests has a compile-time dependency on EnvTokenKit.
            // This is an acceptable, conscious trade-off: GitHubClientTests is a test
            // target, not a shipped library, so the extra dependency does not widen the
            // public API surface or create a production coupling.
            //
            // Coupling boundary: StubEnvTokenProvider imports EnvTokenKit for one reason
            // only — to name the `EnvTokenProviding` protocol in its conformance declaration.
            // It does NOT use ShellTokenResult or any other EnvTokenKit type beyond the
            // protocol itself. Its result vocabulary is a local `StubEnvResult` enum defined
            // inside StubEnvTokenProvider.swift, which mirrors the three outcomes
            // (found/notFound/failed) without referencing any EnvTokenKit internal type.
            // If StubEnvTokenProvider ever needs to cross into internal EnvTokenKit types
            // (e.g. ShellResolutionOutcome), it must move into EnvTokenKit itself as a
            // test-support type rather than silently growing this cross-target coupling.
            // The compiler will not catch this drift — it must be enforced by code review.
            dependencies: ["GitHubClient", "EnvTokenKit"],
            path: "Tests/GitHubClientTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
