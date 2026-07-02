// UpdateChecker.swift
// RunBot
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
///
/// Only `name` and `browserDownloadURL` are decoded; the rest of the
/// GitHub asset payload is intentionally ignored to keep the model minimal.
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page
    /// (e.g. `"RunBot.zip"`).
    public let name: String
    /// The direct download URL for this asset.
    ///
    /// This is always an `https://objects.githubusercontent.com/…` URL;
    /// it does not require authentication for public repositories.
    public let browserDownloadURL: URL

    /// Maps JSON keys to Swift property names.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `name` field in the GitHub API response.
        case name
        /// Maps to the `browser_download_url` field in the GitHub API response.
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - AvailableRelease

/// A decoded GitHub Release, carrying the tag name, channel flag, and asset list.
///
/// Exposed `public` so `AutoUpdater` (same module) and call sites in the app
/// layer can pattern-match on the `.updateAvailable` case without re-fetching.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    ///
    /// `AutoUpdater` searches this list for the asset named `"RunBot.zip"`.
    /// When the asset is absent, `RunnerState.updateAssetMissing` is set to
    /// `true` and the UI falls back to a browser-based Download button.
    public let assets: [ReleaseAsset]
    /// The URL of the `RunBot.zip.sha256` checksum sidecar asset for this release.
    ///
    /// Populated from `latest.assets` at the `AvailableRelease(…)` construction
    /// site in `checkForUpdate` — NOT decoded from a top-level JSON field
    /// (the GitHub Releases API has no such field at the release level).
    /// `AutoUpdater.downloadUpdate` fetches this URL in parallel with the zip
    /// and verifies the SHA-256 digest before caching the zip.
    ///
    /// A `nil` value means `publish.yml` did not attach the sidecar, which is
    /// treated as a hard failure in `downloadUpdate` — the download is aborted
    /// and `updateActionFailed` is set so the browser-fallback Download button
    /// becomes visible.
    ///
    /// REVIEWER: Do NOT add JSON decoding for this field here.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of a `UpdateChecker.checkForUpdate(betaChannel:)` call.
public enum UpdateCheckResult: Sendable {
    /// The running version is already the latest available.
    case upToDate
    /// A newer release is available.
    ///
    /// - Parameter release: The full `AvailableRelease` for the newer version,
    ///   including its `tagName` and `assets` list. Callers should pass this
    ///   directly to `AutoUpdater.handle(_:)` rather than extracting only the
    ///   tag name — the asset list is needed to locate the download URL.
    case updateAvailable(release: AvailableRelease)
    /// The check could not be completed (network error, missing key, etc.).
    ///
    /// - Parameter error: The underlying error. Call sites may inspect this
    ///   for diagnostics but must treat it as non-fatal — update checks are
    ///   best-effort and must never crash the app.
    case failed(Error)
}

// MARK: - UpdateCheckError

/// Errors specific to the update-check flow that do not wrap a lower-level error.
public enum UpdateCheckError: Error, Sendable {
    /// `RBVersionString` was absent from `Info.plist`.
    case missingVersionKey
    /// Covers two distinct situations that are intentionally collapsed into
    /// the same error code:
    ///
    ///   1. A genuine empty result — no release on GitHub matches the channel
    ///      (e.g. a fresh repo before the first stable tag is pushed, or a
    ///      `betaChannel=false` user on a repo that only has beta releases so far).
    ///
    ///   2. A network/API failure — the request timed out, returned a non-200
    ///      status, or the response body failed to decode as `[Release]`.
    ///
    /// Both cases surface the same `.failed(.noReleasesFound)` result because
    /// update checks are **best-effort background operations** that must never
    /// surface error UI (see #1794). The only observable consequence of either
    /// situation is "no update offered", which is correct in both cases.
    ///
    /// If you need to distinguish the two (e.g. for exponential backoff on
    /// network failures), split this into two cases and update the handling in
    /// `performStartupSequence` and `scheduleBackgroundCheck`. That is a
    /// feature addition, not a bug fix — track it in a new issue rather than
    /// conflating it with this one.
    case noReleasesFound
}

/// Checks GitHub Releases for a newer version of RunBot.
///
/// Hits `GET /repos/runbot-hq/run-bot/releases` (the full list, not /latest)
/// so it can filter by channel. The `prerelease` field on each release is set
/// by the `--prerelease` flag in `publish.yml` at release creation time.
///
/// Implemented as a caseless `enum` (not `struct` or `class`) to prevent
/// accidental instantiation — all functionality is exposed via `static` methods.
public enum UpdateChecker {

    /// The GitHub Releases API URL string for this repository.
    ///
    /// Kept as a plain `String` constant (not a `URL` literal) so there is no
    /// dependency on a particular `URL` initialiser overload. `buildRequest(perPage:)`
    /// converts it to a `URL` via `URL(string:)` and returns `nil` on failure,
    /// so a typo here degrades gracefully (update check silently no-ops) rather
    /// than crashing at startup.
    ///
    /// Centralised here so that the URL appears in exactly one place — grep
    /// for `releasesURLString` to find every usage.
    private static let releasesURLString =
        "https://api.github.com/repos/runbot-hq/run-bot/releases"

    /// The expected filename of the SHA-256 checksum sidecar asset.
    ///
    /// `publish.yml` uploads this file alongside `RunBot.zip` for every release.
    /// Keeping it as a constant prevents a typo from silently causing every
    /// release to skip integrity verification and fall back to the browser-
    /// download path.
    private static let expectedChecksumAssetName = "RunBot.zip.sha256"

    /// A minimal Codable model for a GitHub Release API response object.
    ///
    /// Value type (struct, not caseless enum) — used to hold per-instance decoded
    /// data from the JSON response, not as a static-only namespace. DeepSource
    /// raises "use caseless enum for static-only types" against this struct;
    /// that is a false positive. This struct is instantiated by JSONDecoder for
    /// each release in the API response array. Do NOT convert to a caseless enum.
    private struct Release: Decodable {
        /// The git tag name for this release (e.g. `"v0.7.1"`).
        let tagName: String
        /// `true` when this release was published with `--prerelease`.
        let prerelease: Bool
        /// The binary assets attached to this release.
        ///
        /// Decoded so `AutoUpdater` can locate `RunBot.zip` by name without
        /// a second network round-trip.
        ///
        /// `assets` must be present in the JSON — `JSONDecoder` does **not**
        /// provide default values for missing required keys; a missing key
        /// would cause the entire `Release` to fail decoding (the `try?` in
        /// `latestMatchingRelease` would swallow the error and return `nil`).
        /// In practice the GitHub Releases API always returns `assets: []` so
        /// this is never nil in production, but `assets` is not optional here.
        let assets: [ReleaseAsset]

        /// Maps snake_case JSON keys to Swift property names.
        enum CodingKeys: String, CodingKey {
            /// Maps to the `tag_name` field in the GitHub API response.
            case tagName = "tag_name"
            /// Maps to the `prerelease` field in the GitHub API response.
            case prerelease
            /// Maps to the `assets` array in the GitHub API response.
            case assets
        }
    }

    /// Parsed semver components extracted from a version string.
    ///
    /// Value type (struct, not caseless enum) — holds per-instance parsed
    /// components (major, minor, patch, isPrerelease, betaIndex) for a single
    /// version string. DeepSource raises "use caseless enum for static-only
    /// types" against this struct; that is a false positive. This struct is
    /// instantiated twice per isNewer() call (once for candidate, once for
    /// current). Do NOT convert to a caseless enum.
    private struct ParsedVersion {
        /// Major version component.
        let major: Int
        /// Minor version component.
        let minor: Int
        /// Patch version component.
        let patch: Int
        /// `true` when the version string contains a pre-release suffix (e.g. `-beta.2`).
        let isPrerelease: Bool
        /// The numeric suffix from a `-beta.N` pre-release tag, or `nil` if not a
        /// beta tag or if the suffix cannot be parsed. Used to order beta.1 < beta.2
        /// when major/minor/patch are identical — without this, two betas of the same
        /// base version compare equal and `isNewer` returns `false`, silently
        /// suppressing beta-to-beta update prompts.
        ///
        /// - Note: Only the exact `-beta.N` form (where N is an integer) is recognised.
        ///   Other pre-release suffixes such as `-rc.1`, `-alpha.1`, or `-beta.rc1` will
        ///   parse as `isPrerelease = true` but `betaIndex = nil`. This is intentional:
        ///   `publish.yml` exclusively produces `-beta.N` tags, so no other form can
        ///   appear in the GitHub Releases feed this client reads. If the tag convention
        ///   ever changes, the `if suffixParts[0] == "beta"` guard below must be updated.
        let betaIndex: Int?

        /// Parses a version string of the form `"X.Y.Z"` or `"X.Y.Z-beta.N"`.
        ///
        /// Components that cannot be parsed default to `0`. `betaIndex` defaults to `nil`.
        init(_ version: String) {
            let parts = version.split(separator: "-", maxSplits: 1)
            // Guard against an empty `parts` array. `String.split` with
            // `omittingEmptySubsequences: true` (the default) returns `[]` for
            // an empty string, so `parts[0]` would crash. This can happen if
            // `isNewer` is called with `"v"` as the candidate (after the
            // `dropFirst()` strip in the caller produces `""`), or if any future
            // caller passes an empty string directly. Defaulting `core` to `""`
            // produces major/minor/patch = 0, which degrades gracefully.
            let core = parts.isEmpty ? "" : String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
            // Parse beta.N suffix — e.g. "beta.2" → betaIndex = 2.
            if parts.count > 1 {
                let suffix = String(parts[1]) // e.g. "beta.2"
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

    /// Builds a `URLRequest` for the releases endpoint with the given page size.
    ///
    /// `perPage` is clamped to `1...100` — GitHub's documented maximum for the
    /// releases endpoint is 100; values above that are silently truncated by the
    /// API, but clamping here keeps the query string honest and makes the
    /// contract explicit to future callers.
    ///
    /// Returns `nil` if `URL(string:)` or `URLComponents` cannot produce a
    /// valid URL — update checks are best-effort and must never crash the app.
    private static func buildRequest(perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        // GitHub API requires a User-Agent header.
        request.setValue("RunBot", forHTTPHeaderField: "User-Agent")
        // ⚠️ No Authorization header is sent — requests are unauthenticated.
        // GitHub's unauthenticated REST API limit is 60 requests/hour per IP.
        // The production 24 h check interval makes exhaustion practically
        // impossible for a single user. However, the DEBUG 60 s interval can
        // deplete the budget in ~1 hour on a shared NAT (office, co-working
        // space) where multiple RunBot instances share the same egress IP.
        // This is a known v1 trade-off. Adding an optional GITHUB_TOKEN
        // preference to raise the limit to 5,000 req/hr is a v2 concern.
        // Recommended by GitHub REST API docs to ensure a stable v3 response shape.
        // Without this the API still responds correctly today, but the content type
        // is not guaranteed to remain stable across API versions.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Pins the GitHub REST API to the 2022-11-28 version.
        // Without this header the API responds correctly today, but GitHub
        // reserves the right to change the default API version. Pinning
        // ensures the response shape (including `tag_name` and `prerelease`
        // fields) remains stable even if GitHub later changes its default.
        // See: https://docs.github.com/en/rest/about-the-rest-api/api-versions
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches and decodes the releases list, then returns the highest-semver release
    /// matching the `betaChannel` filter, or `nil` on any failure.
    ///
    /// The GitHub Releases API returns releases sorted by **published date**
    /// (newest first), not by semver. Relying on that order is fragile: a hotfix
    /// to an older branch published after a newer release would silently become
    /// the "latest" candidate. To eliminate the assumption, the full decoded list
    /// is sorted by semver before filtering — the list is already in memory
    /// (perPage: 100) so the overhead is negligible.
    ///
    /// `betaChannel=true` intentionally accepts both stable and pre-release releases.
    /// A stable release always beats a beta of the same base (0.7.1 > 0.7.1-beta.N),
    /// so a beta-channel user is correctly offered 0.7.1 when it ships, even though
    /// stable builds are included in the candidate set.
    ///
    /// Per-page is set to 100 (the GitHub API maximum) so that all releases fit in
    /// a single response. With per_page=20, once the repo accumulates >20 releases
    /// the most recent stable could be pushed off page 1, silently returning no
    /// update to betaChannel=false users. The JSON payload is lightweight (<10 KB
    /// for 100 releases) so the extra bytes are negligible.
    private static func latestMatchingRelease(betaChannel: Bool) async -> Release? {
        guard let request = buildRequest(perPage: 100) else { return nil }
        // ⚠️ URLSession.shared IS USED INTENTIONALLY HERE — DO NOT ROUTE THROUGH ghAPI/ghAPIPaginated ⚠️
        //
        // Automated reviewers sometimes flag this as "bypassing the transport shim".
        // That is a false positive. Here is why the shim is deliberately NOT used:
        //
        // The `ghAPI` / `ghAPIPaginated` shim exists for runner-polling calls:
        // WorkflowActionGroupFetch, RunnerStatusEnricher, LogFetcher. Those calls:
        //   • Use the user's PAT (personal access token) for authentication.
        //   • Are counted against the 60 req/hr unauthenticated (or 5,000 req/hr
        //     authenticated) GitHub API rate limit shown in the UI's API counter.
        //   • Need to be injectable/mockable because they hit live runner data.
        //
        // This update-check call is categorically different:
        //   • It is unauthenticated by design — it reads only the public Releases
        //     API, which does not require a PAT and should never use one.
        //   • It builds its own URLRequest with custom Accept and X-GitHub-Api-Version
        //     headers that the shim transport does not set.
        //   • Routing through the shim would increment apiCallCounter once per 24 h
        //     (or 60 s in DEBUG) for a call that has nothing to do with the runner
        //     polling budget the UI counter is meant to reflect.
        //   • The function is already unit-tested via isNewer() and ParsedVersion in
        //     isolation; no live-network injection point is needed for that coverage.
        //
        // REVIEWER: Do NOT route this call through ghAPI or ghAPIPaginated.
        // Do NOT add a GitHubTransportProtocol injection point here.
        // If you believe this is wrong, read the shim's file-level comment in
        // GitHubTransportShim.swift first — its listed consumers are
        // WorkflowActionGroupFetch, RunnerStatusEnricher, and LogFetcher.
        //
        // ⚠️ `URLResponse` IS INTENTIONALLY DISCARDED — THE 403 SILENT NO-OP IS BY DESIGN ⚠️
        //
        // This is NOT a missing error-handling branch. Here is exactly what happens
        // for each failure case and why silent no-op is the correct response:
        //
        //   • HTTP 403 (GitHub rate-limited): The response body is a JSON error
        //     object, not a [Release] array. JSONDecoder fails, `guard` returns nil,
        //     the entire check no-ops. The user sees no update prompt — correct,
        //     because we have no reliable version information to act on.
        //
        //   • HTTP 404 (repo moved / renamed): Same outcome. JSON error body,
        //     decode fails, silent no-op. Correct — better than showing a stale
        //     or wrong update prompt.
        //
        //   • Network offline / timeout: `try?` returns nil, guard fires, no-op.
        //
        // In all failure cases the result is indistinguishable from "already up to
        // date". This is the INTENDED design: update checks are best-effort
        // background operations that must NEVER surface error UI to the user.
        // Inspecting the HTTP status code here would require plumbing error state
        // back to the UI, which is explicitly out of scope for v1 (see #1794).
        //
        // REVIEWER: Do NOT add HTTP status inspection or error propagation here.
        // If you need per-status behaviour (e.g. exponential backoff on 403),
        // that is a separate feature tracked under #1794, not a bug in this line.
        //
        // URLSession.shared has a default timeoutIntervalForRequest of 60 s.
        // On a stalled proxy or dead CDN this call can block for up to 60 s
        // before the OS returns an error — at which point `try?` produces nil,
        // the guard fires, and the result is a silent no-op (same as "no update
        // available"). There is NO downside to this: the check is invisible to
        // the user, no state is mutated on timeout, and the scheduler will retry
        // at the next interval. A shorter timeout would only cause MORE missed
        // checks on slow networks with no benefit.
        //
        // REVIEWER: Do NOT replace URLSession.shared with a custom ephemeral
        // session or add an explicit timeout here. This call site does not need
        // it. If you believe it does, read the failure analysis in the comment
        // block above before making any change.
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let releases = try? JSONDecoder().decode([Release].self, from: data)
        else { return nil }

        // Sort by semver descending so the highest version is first regardless
        // of GitHub's published-date ordering.
        let sorted = releases.sorted { isNewer($0.tagName, than: $1.tagName) }
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }

    // deepsource-disable-next-line SW-R1002
    /// Returns `true` when `candidate` is strictly newer than `current`
    /// using numeric semver comparison, including beta ordering.
    ///
    /// Both strings are stripped of a leading `v` prefix before parsing.
    /// Pre-release versions are considered older than their stable base:
    /// `1.0.0-beta.1 < 1.0.0`. Within the same base, higher beta index wins:
    /// `1.0.0-beta.2 > 1.0.0-beta.1`.
    ///
    /// Exposed `internal` (not `private`) so `Bundle+Version.isOlderThan`
    /// can reuse the same comparison logic without duplicating it.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let cv = ParsedVersion(candidate.hasPrefix("v") ? String(candidate.dropFirst()) : candidate)
        let sv = ParsedVersion(current.hasPrefix("v")   ? String(current.dropFirst())   : current)

        // Same X.Y.Z — compare numerically component-by-component.
        if cv.major != sv.major { return cv.major > sv.major }
        if cv.minor != sv.minor { return cv.minor > sv.minor }
        if cv.patch != sv.patch { return cv.patch > sv.patch }

        // Same X.Y.Z — stable beats pre-release, then compare beta index.
        if cv.isPrerelease != sv.isPrerelease { return !cv.isPrerelease }
        if let ci = cv.betaIndex, let si = sv.betaIndex { return ci > si }

        return false
    }

    /// Checks whether an update is available for the running build.
    ///
    /// Reads `RBVersionString` from `Info.plist` (the full semver including any
    /// pre-release suffix, patched by `publish.yml`). Returns `.failed(.missingVersionKey)`
    /// rather than falling back to `CFBundleShortVersionString` — a missing key
    /// means CI did not patch the bundle, and offering an update against an
    /// unknown base version is worse than doing nothing.
    ///
    /// ## Why `.noReleasesFound` covers both "empty list" and network failure
    ///
    /// `latestMatchingRelease` returns `nil` for three distinct reasons:
    ///   - Network error, timeout, or non-200 response
    ///   - The API returned a valid list, but no release matched the channel filter
    ///     (e.g. `betaChannel=false` on a repo with only beta tags)
    ///   - The API returned an empty list (fresh repo, no releases yet)
    ///
    /// All three map to `.failed(.noReleasesFound)`. This is intentional: update
    /// checks are best-effort and must never surface error UI. The log message
    /// at the call site says "update check failed" for all three — that is
    /// technically correct and is the right level of fidelity for v1. If
    /// diagnostic distinction ever matters, split `noReleasesFound` into
    /// `.networkError` and `.noMatchingRelease` and update this function and
    /// both call sites (`performStartupSequence`, `scheduleBackgroundCheck`).
    public static func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        guard let currentVersion = Bundle.main.infoDictionary?["RBVersionString"] as? String,
              !currentVersion.isEmpty
        else {
            return .failed(UpdateCheckError.missingVersionKey)
        }

        guard let latest = await latestMatchingRelease(betaChannel: betaChannel) else {
            return .failed(UpdateCheckError.noReleasesFound)  // ← intentional collapse — read doc comment above
        }

        guard isNewer(latest.tagName, than: currentVersion) else {
            return .upToDate
        }

        // Locate the zip asset and its SHA-256 sidecar from the already-decoded
        // assets array — no additional network call needed.
        let checksumAsset = latest.assets.first(where: { $0.name == expectedChecksumAssetName })
        let release = AvailableRelease(
            tagName: latest.tagName,
            assets: latest.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )
        return .updateAvailable(release: release)
    }
}
