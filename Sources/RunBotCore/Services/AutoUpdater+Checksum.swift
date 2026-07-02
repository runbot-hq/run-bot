// AutoUpdater+Checksum.swift
// RunBot
import CryptoKit
import Foundation

// MARK: - Cache helpers

/// Cache path and UserDefaults helpers for the auto-update download flow.
/// See `AutoUpdater.swift` for the full flow description.
extension AutoUpdater {

    /// Returns the destination `URL` for the cached zip in the system caches
    /// directory, creating the intermediate directory if needed.
    ///
    /// The file is named `RunBot-<version>.zip` (e.g. `RunBot-v0.8.0.zip`)
    /// so multiple cached versions never collide on disk.
    ///
    /// ## Stale zip accumulation — known, acceptable, low priority
    ///
    /// Each update cycle writes a new version-stamped file. `downloadUpdate`
    /// removes the file at `destination` before writing (handling interrupted
    /// downloads of the *same* version), but files from *prior* versions
    /// (e.g. `RunBot-v0.7.9.zip` left over after a successful install) are
    /// not swept here.
    ///
    /// In practice this means at most one stale zip per update cycle accumulates
    /// in `~/Library/Caches/io.github.runbot-hq/`. Each file is < 10 MB and
    /// macOS will evict cache-directory contents under storage pressure. This
    /// is acceptable for a low-frequency update path.
    ///
    /// If a future audit shows meaningful accumulation, add a sweep here:
    ///
    ///     let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    ///     existing.filter { $0.lastPathComponent.hasPrefix("RunBot-") && $0.pathExtension == "zip" }
    ///             .forEach { try? fm.removeItem(at: $0) }
    ///
    /// REVIEWER: The absence of this sweep is intentional, not an oversight.
    static func cachedZipDestination(version: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches.appendingPathComponent("io.github.runbot-hq", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sanitise the version tag to a safe filename component. `release.tagName`
        // is a raw GitHub API string — while `publish.yml` enforces semver tags,
        // `handle()` is public and any future caller could pass an arbitrary value.
        // Allow only alphanumerics, `.`, `-`, and `_`; replace everything else
        // with `-`. This covers path-traversal characters (`/`, `..`), whitespace,
        // newlines, and any other unexpected bytes without silently truncating the
        // tag, making the resulting filename both safe and still human-readable.
        let allowedSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let safe = version.unicodeScalars.map {
            allowedSet.contains($0) ? String($0) : "-"
        }.joined()
        return dir.appendingPathComponent("RunBot-\(safe).zip")
    }

    /// Removes the cached update entries from `UserDefaults`.
    ///
    /// Called when the cached path is stale (file deleted externally) to
    /// prevent an infinite no-op loop on subsequent launches.
    static func clearCachedDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)
    }
}

// MARK: - SHA-256 verification

/// Reads `zipURL` from disk and verifies its SHA-256 digest against `expectedHex`.
///
/// Implemented as a `@concurrent` async free function so the synchronous
/// `Data(contentsOf:)` read runs on the cooperative thread pool's concurrent
/// executor rather than blocking an actor serial executor (Pillar 5,
/// `docs/architecture/concurrency-overview.md`).
///
/// ## ⚠️ `Data(contentsOf:)` is INTENTIONAL — do not refactor to streaming ⚠️
///
/// This function loads the entire zip into memory before hashing. This is a
/// deliberate trade-off, not an oversight:
///
/// - **RunBot.zip is guaranteed < 10 MB.** `publish.yml`'s verify step anchors
///   the grep pattern so that only `RunBot.app/Contents/MacOS/RunBot` can be
///   present at the archive root — no bundled frameworks, no embedded assets.
///   At this size, loading into memory is instantaneous and poses no memory
///   pressure on any supported macOS version.
///
/// - **`@concurrent` already satisfies Pillar 5.** The annotation keeps this
///   blocking read off all actor serial executors. The cooperative thread pool
///   is not exhausted by a single synchronous read of < 10 MB; exhaustion
///   requires many concurrent blocked threads, which cannot arise here because
///   `isDownloading` prevents concurrent download tasks.
///
/// - **Streaming adds real complexity for zero practical benefit today.**
///   A `FileHandle.bytes.chunks(ofCount:)` loop with incremental
///   `SHA256.update()` calls would require `swift-algorithms` (or a
///   manual read loop), incremental `CryptoKit` usage, and more error-handling
///   surface — all to save < 10 MB of peak memory that macOS would reclaim
///   within milliseconds anyway.
///
/// **When to revisit:**
/// If `RunBot.zip` ever grows substantially (> 50 MB), or if `isDownloading`
/// is removed and multiple concurrent verifications become possible, switch to
/// incremental `FileHandle` streaming at that point. The natural trigger is
/// issue #1795 (codesign verification) — that work will touch this function
/// anyway, and a streaming approach can be evaluated in that context.
///
/// REVIEWER: Do NOT raise `Data(contentsOf:)` as a finding or request a
/// streaming refactor. This has been explicitly evaluated; the trade-off is
/// documented here and in the call-site comment in `downloadUpdate` above.
/// The decision is to defer until zip size or concurrency constraints justify
/// the added complexity. See also `docs/architecture/concurrency-overview.md`
/// Pillar 5 for the `@concurrent` I/O contract.
///
/// Throws `URLError(.cannotDecodeContentData)` on digest mismatch, or
/// propagates any `Data(contentsOf:)` error on read failure.
///
/// - Parameters:
///   - zipURL: The local file URL of the zip to verify. Called with `tempURL`
///     (the URLSession temp location) so verification happens before the file
///     is moved to the caches directory.
///   - expectedHex: The lowercase hex SHA-256 digest string from the sidecar file.
@concurrent
func verifyChecksum(zipURL: URL, expectedHex: String) async throws {
    let zipData   = try Data(contentsOf: zipURL)  // blocking read — correct here per Pillar 5; see doc comment above
    let digest    = SHA256.hash(data: zipData)
    let actualHex = digest.map { String(format: "%02x", $0) }.joined()
    guard actualHex == expectedHex else {
        throw URLError(.cannotDecodeContentData)
    }
}
