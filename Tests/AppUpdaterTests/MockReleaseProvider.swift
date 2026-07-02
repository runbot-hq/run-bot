// MockReleaseProvider.swift
// AppUpdaterTests
@testable import AppUpdater

// MARK: - MockReleaseProvider

/// A configurable test double for `ReleaseProvider`.
///
/// `actor` isolation ensures mutation of call-capture properties is safe
/// when tests `await` recorded values — no `@unchecked Sendable` required
/// (Pillar 6). Zero `DispatchQueue` usage (Pillar 5).
///
/// ## Usage
///
/// ```swift
/// let provider = MockReleaseProvider()
/// provider.releaseToReturn = AvailableRelease(tagName: "v2.0.0", assets: [], checksumURL: nil)
/// let updater = AppUpdater(
///     repo: "owner/repo",
///     currentVersion: "1.0.0",
///     assetName: { _ in "App.zip" },
///     schedulerIdentifier: "com.test.update",
///     releaseProvider: provider
/// )
/// ```
actor MockReleaseProvider: ReleaseProvider {

    // MARK: - Configuration

    /// The release to return from `fetchLatestRelease`. `nil` simulates a
    /// network failure or empty releases list.
    var releaseToReturn: AvailableRelease?

    /// Convenience: number of simulated async yield points per fetch call.
    /// Uses `await Task.yield()` (Pillar 5 — no DispatchQueue).
    var simulatedSteps: Int = 1

    // MARK: - Call capture

    /// Number of times `fetchLatestRelease` was called.
    private(set) var fetchCallCount: Int = 0

    /// Alias kept for backward compatibility with existing tests.
    var callCount: Int { fetchCallCount }

    /// The `betaChannel` value last passed to `fetchLatestRelease`.
    private(set) var capturedBetaChannel: Bool?

    /// The `repo` value last passed to `fetchLatestRelease`.
    private(set) var capturedRepo: String?

    // MARK: - Init

    /// Creates a mock with an optional pre-configured release.
    init(releaseToReturn: AvailableRelease? = nil) {
        self.releaseToReturn = releaseToReturn
    }

    /// Mutates `releaseToReturn` from the outside (for tests that can't use
    /// the initialiser after construction).
    func set(releaseToReturn: AvailableRelease?) {
        self.releaseToReturn = releaseToReturn
    }

    // MARK: - ReleaseProvider

    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> AvailableRelease? {
        fetchCallCount += 1
        capturedRepo = repo
        capturedBetaChannel = betaChannel
        for _ in 0..<simulatedSteps { await Task.yield() }
        return releaseToReturn
    }
}
