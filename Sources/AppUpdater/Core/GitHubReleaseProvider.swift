// GitHubReleaseProvider.swift
// AppUpdater

// MARK: - GitHubReleaseProvider

/// The production `ReleaseProvider` — fetches releases from the GitHub
/// Releases API by delegating to `UpdateChecker.fetchLatestAvailableRelease`.
///
/// Zero stored state; conforms to `Sendable` automatically as a value type
/// with no mutable stored properties (Pillar 6).
///
/// This type is the default injected into `AppUpdater.init` — existing call
/// sites require no changes.
public struct GitHubReleaseProvider: ReleaseProvider {
    /// Creates a new `GitHubReleaseProvider`.
    public init() {}

    /// Fetches the latest release for `repo` by delegating to
    /// `UpdateChecker.fetchLatestAvailableRelease`.
    ///
    /// Returns `nil` on any failure (network error, non-200 response, decode
    /// failure, empty list, no channel match). All failure modes are
    /// best-effort and must never surface error UI.
    public func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> AvailableRelease? {
        await UpdateChecker.fetchLatestAvailableRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
    }
}
