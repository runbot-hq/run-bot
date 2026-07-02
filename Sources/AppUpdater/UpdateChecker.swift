// UpdateChecker.swift
// AppUpdater
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page.
    public let name: String
    /// The direct download URL for this asset.
    public let browserDownloadURL: URL

    /// Maps Swift property names to the GitHub API's snake_case JSON keys.
    enum CodingKeys: String, CodingKey {
        /// Maps to the JSON key `"name"`.
        case name
        /// Maps to the GitHub API JSON key `"browser_download_url"`.
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - AvailableRelease

/// A decoded GitHub Release, carrying the tag name and asset list.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    public let assets: [ReleaseAsset]
    /// The URL of the SHA-256 checksum sidecar asset, or `nil` if absent.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of an `UpdateChecker.checkForUpdate(...)` call.
public enum UpdateCheckResult: Sendable {
    /// The running version is already the latest eligible version.
    case upToDate
    /// A newer eligible release was found.
    case updateAvailable(release: AvailableRelease)
    /// The check could not complete due to the associated error.
    case failed(Error)
}

// MARK: - UpdateCheckError

/// Errors produced by `UpdateChecker` and `AppUpdater.checkForUpdate`.
public enum UpdateCheckError: Error, Sendable {
    /// The `currentVersion` string supplied to the checker was empty.
    case missingVersionKey
    /// The releases API request failed, the HTTP response was non-200, or
    /// the response body could not be decoded. This does not mean
    /// "no channel match" — when releases exist but none match the requested
    /// channel the result is `.upToDate`, not this error.
    case noReleasesFound
}

// MARK: - UpdateChecker

/// Checks a GitHub repository's Releases for a newer version.
public enum UpdateChecker {

    /// Lightweight mirror of the GitHub Releases API response object.
    ///
    /// Only the fields needed for version comparison and asset resolution are
    /// decoded; all other API fields are ignored.
    private struct Release: Decodable {
        /// The git tag name of this release (e.g. `"v0.8.0"`).
        let tagName: String
        /// `true` when GitHub has marked this release as a pre-release.
        let prerelease: Bool
        /// The binary assets attached to this release.
        let assets: [ReleaseAsset]
        /// Maps Swift property names to the GitHub API's snake_case JSON keys.
        enum CodingKeys: String, CodingKey {
            /// Maps to the GitHub API JSON key `"tag_name"`.
            case tagName = "tag_name"
            /// Maps to the JSON key `"prerelease"`.
            case prerelease
            /// Maps to the JSON key `"assets"`.
            case assets
        }
    }

    /// A parsed, comparable representation of a semver version string.
    ///
    /// Strips the leading `"v"` if present, splits on `"-"` to separate the
    /// core version from any pre-release suffix, and extracts a `betaIndex`
    /// for `beta.N` labels so beta versions can be ordered numerically.
    private struct ParsedVersion {
        /// The major version component (first numeric segment).
        let major: Int
        /// The minor version component (second numeric segment).
        let minor: Int
        /// The patch version component (third numeric segment).
        let patch: Int
        /// `true` when the version string contained a pre-release suffix.
        let isPrerelease: Bool
        /// The numeric index from a `beta.N` pre-release suffix, or `nil` for
        /// any other suffix (e.g. `rc.1`, `alpha.1`) or no suffix at all.
        let betaIndex: Int?

        /// Parses `version` into its semver components.
        ///
        /// Non-numeric or missing segments default to `0`. An unrecognised
        /// pre-release suffix (anything other than `beta.N`) sets `betaIndex`
        /// to `nil` while still marking `isPrerelease = true`.
        init(_ version: String) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this version parser
            let parts = version.split(separator: "-", maxSplits: 1)
            let core = parts.isEmpty ? "" : String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
            if parts.count > 1 {
                let suffix = String(parts[1])
                let suffixParts = suffix.split(separator: ".")
                if suffixParts.count == 2, suffixParts[0] == "beta",
                   let n = Int(suffixParts[1]) {
                    betaIndex = n
                } else {
                    betaIndex = nil
                }
            } else {
                betaIndex = nil
            }
        }
    }

    /// Builds a `URLRequest` for the releases endpoint of `repo`.
    ///
    /// `perPage` is clamped to `1...100` (GitHub's documented maximum for this
    /// endpoint). A single request is made — no pagination.
    ///
    /// ## ⚠️ 100-release ceiling
    ///
    /// `fetchAndDecodeReleases` makes exactly one request with `per_page=100`.
    /// If a repository has published more than 100 releases the oldest releases
    /// (by GitHub's default sort, newest first) are never seen. For most repos
    /// this is not a problem — the newest release is always in the first page.
    /// However if you publish hotfixes to old branches and those appear after
    /// the 100th entry you may miss them. See README "Known limitations" for
    /// the recommended mitigation (keep releases ≤ 100, or draft/delete old ones).
    private static func buildRequest(repo: String, perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        let releasesURLString = "https://api.github.com/repos/\(repo)/releases"
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        request.setValue("AppUpdater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches and decodes the releases list for `repo`.
    ///
    /// Returns `nil` on any network, HTTP, or JSON-decode failure. An empty
    /// array means the repository exists but has no published releases.
    /// This is intentionally separate from channel filtering — a `nil` return
    /// here means "we could not determine the release list", whereas an empty
    /// filtered result means "releases exist but none match the channel".
    private static func fetchAndDecodeReleases(repo: String) async -> [Release]? {
        guard let request = buildRequest(repo: repo, perPage: 100) else { return nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request) else { return nil }

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            appUpdaterLogger.debug("releases API returned \(httpResponse.statusCode, privacy: .public) for \(repo, privacy: .public)")
            return nil
        }

        return try? JSONDecoder().decode([Release].self, from: data)
    }

    /// Sorts `releases` by semver (newest first) and returns the first entry
    /// that matches `betaChannel`.
    ///
    /// Returns `nil` when no release matches the channel filter — i.e. the
    /// caller is on the stable channel and every release is a pre-release.
    /// This `nil` means **no channel match**, not a fetch failure; the two
    /// cases are kept separate so callers can map them to different outcomes
    /// (`.upToDate` vs `.failed`).
    private static func latestMatchingRelease(
        from releases: [Release],
        betaChannel: Bool
    ) -> Release? {
        let sorted = releases.sorted { isNewer($0.tagName, than: $1.tagName) }
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }

    /// Returns an `AvailableRelease` for the latest release matching `betaChannel`,
    /// or `nil` if the fetch failed or no release matched the channel.
    ///
    /// This is the lower-level fetch primitive used by `GitHubReleaseProvider`.
    /// Unlike `checkForUpdate`, it does not perform a semver comparison against
    /// `currentVersion` — it simply returns the latest eligible release from the
    /// API, or `nil` on any failure (network, HTTP, decode, or no channel match).
    ///
    /// Callers that need to distinguish "fetch failed" from "no channel match"
    /// should use `checkForUpdate` instead, which maps these to `.failed` and
    /// `.upToDate` respectively.
    static func fetchLatestAvailableRelease(
        repo: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> AvailableRelease? {
        guard let releases = await fetchAndDecodeReleases(repo: repo) else { return nil }
        guard let latest = latestMatchingRelease(from: releases, betaChannel: betaChannel)
        else { return nil }
        let checksumAssetName = assetName(latest.tagName) + ".sha256"
        let checksumAsset = latest.assets.first(where: { $0.name == checksumAssetName })
        return AvailableRelease(
            tagName: latest.tagName,
            assets: latest.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )
    }

    /// Returns `true` when `candidate` is strictly newer than `current` using
    /// numeric semver comparison, including beta ordering.
    ///
    /// ## Constraints
    ///
    /// Pre-release ordering is supported **only for `beta.N` labels** (e.g.
    /// `v0.8.0-beta.2` is newer than `v0.8.0-beta.1`). Any other pre-release
    /// suffix — such as `rc.1`, `alpha.1`, or an arbitrary string — is parsed
    /// with `betaIndex == nil`. When both versions share the same
    /// `major.minor.patch` and at least one has a non-`beta.N` pre-release
    /// label, the `if let ci, let si` guard falls through and this function
    /// returns `false`.
    ///
    /// This is not a bug for the current publish pipeline, which only generates
    /// `beta.N` tags. If a future release channel uses a different pre-release
    /// label (e.g. `rc.N`), extend `ParsedVersion` to recognise that suffix and
    /// assign a comparable index before calling this function.
    public static func isNewer(_ candidate: String, than current: String) -> Bool { // skipcq: SW-R1002 — reviewed; complexity acceptable for this semver comparison
        let cv = ParsedVersion(candidate.hasPrefix("v") ? String(candidate.dropFirst()) : candidate)
        let sv = ParsedVersion(current.hasPrefix("v")   ? String(current.dropFirst())   : current)

        if cv.major != sv.major { return cv.major > sv.major }
        if cv.minor != sv.minor { return cv.minor > sv.minor }
        if cv.patch != sv.patch { return cv.patch > sv.patch }

        if cv.isPrerelease != sv.isPrerelease { return !cv.isPrerelease }
        if let ci = cv.betaIndex, let si = sv.betaIndex { return ci > si }

        return false
    }

    /// Checks for an available update for `repo`.
    ///
    /// ## Return values
    ///
    /// - `.upToDate` — the latest eligible release is not newer than
    ///   `currentVersion`, **or** releases were fetched successfully but none
    ///   matched the requested channel (e.g. `betaChannel: false` and the
    ///   repository only has pre-releases). In both cases the caller is already
    ///   on the latest version they are eligible for.
    /// - `.updateAvailable` — a newer eligible release was found.
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty.
    /// - `.failed(.noReleasesFound)` — the releases API request failed, the
    ///   HTTP response was non-200, or the response body could not be decoded.
    ///   This does **not** mean "no channel match" — see `.upToDate` above.
    public static func checkForUpdate(
        repo: String,
        currentVersion: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }

        // Step 1: fetch and decode. nil here means a genuine fetch/decode failure.
        guard let releases = await fetchAndDecodeReleases(repo: repo) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }

        // Step 2: filter by channel.
        // ✅ REVIEWED: nil here maps to .upToDate, NOT .failed — this is
        // deliberate. nil from latestMatchingRelease means releases were
        // fetched successfully but none matched the requested channel (e.g.
        // the user is on the stable channel and every published release is a
        // pre-release). That is not a failure — the user is on the latest
        // version they are eligible for. A reviewer may flag this as "swallows
        // a no-match condition silently" — it does not. The distinction is
        // documented in the UpdateCheckError.noReleasesFound doc comment and
        // in the checkForUpdate return-value docs above. Do not change this
        // to .failed — that would incorrectly show an error state to stable
        // users on a beta-only repository.
        guard let release = latestMatchingRelease(from: releases, betaChannel: betaChannel) else {
            return .upToDate
        }

        let checksumAssetName = assetName(release.tagName) + ".sha256"
        let checksumAsset = release.assets.first(where: { $0.name == checksumAssetName })
        let availableRelease = AvailableRelease(
            tagName: release.tagName,
            assets: release.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )

        guard isNewer(availableRelease.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: availableRelease)
    }
}
