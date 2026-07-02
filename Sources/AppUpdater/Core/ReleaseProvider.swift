// ReleaseProvider.swift
// AppUpdater

// MARK: - ReleaseProvider

/// Abstracts the release-fetch layer so `AppUpdater` can be tested
/// without a live network. The protocol is intentionally narrow —
/// one method returning a raw `AvailableRelease?`. `AppUpdater` owns
/// the `isNewer` comparison; this type only fetches.
///
/// Conforming types must be `Sendable` (Pillar 6 — non-isolated
/// `Sendable` structs for business logic).
///
/// ## Production conformance
/// `GitHubReleaseProvider` is the default production implementation.
/// It delegates to `UpdateChecker.fetchLatestAvailableRelease` and
/// carries no stored state.
///
/// ## Test conformance
/// `MockReleaseProvider` (in `AppUpdaterTests`) is an `actor` that
/// captures call arguments and returns a configurable `AvailableRelease?`.
public protocol ReleaseProvider: Sendable {
    /// Fetches the latest release for `repo` matching the given channel,
    /// or returns `nil` on any failure (network error, empty list, decode
    /// failure).
    ///
    /// Failures are best-effort and must never surface error UI — a `nil`
    /// return is always treated as "no update available" by the caller.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug.
    ///   - betaChannel: When `true`, pre-release builds are candidates.
    ///   - assetName: Maps a tag name to the expected zip asset filename;
    ///     used to resolve the SHA-256 sidecar URL
    ///     (`<assetName(tagName)>.sha256`) from the release's asset list.
    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> AvailableRelease?
}
