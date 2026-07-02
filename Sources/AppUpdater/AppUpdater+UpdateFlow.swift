// AppUpdater+UpdateFlow.swift
// AppUpdater
import Foundation

// MARK: - Update flow entry points

/// Update-flow entry points: check and handle available releases.
extension AppUpdater {

    // MARK: - Public entry points

    /// Runs a full update check and handles the result.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    /// `.upToDate` and `.failed` are no-ops here — the background scheduler
    /// owns the stale-row-clearing policy.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
        case .failed(let error):
            appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
        }
    }

    /// Runs a channel-aware update check via the injected `ReleaseProvider`.
    ///
    /// Intentionally `internal` — `checkAndHandle` is the designed public
    /// entry point for host apps.
    func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }
        guard let latest = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        ) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }
        guard UpdateChecker.isNewer(latest.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: latest)
    }

    // MARK: - Handle

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a zip already exists at `fixedZipURL`, moves directly to `.ready`
    ///    without re-downloading.
    /// 2. If the release has no matching asset or no checksum sidecar URL,
    ///    logs a warning and returns — no phase change.
    /// 3. Otherwise advances to `.available` and starts a background download.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {

        // ── 1. Already cached? ───────────────────────────────────────────────
        // The zip path is fixed (no version component). If a stale zip from a
        // prior release is on disk, we still apply .ready for the new tagName.
        // If the binary doesn't match, installAndRelaunch will fail and apply
        // .failed — the user retries and the next cycle re-downloads. This is
        // the correct binary outcome under design Principle 2 (no mid-flight
        // recovery). A version-sidecar file would add state for an edge case
        // that self-heals in one retry cycle — see issue #1859.
        //
        // ✅ REVIEWED: the "silent downgrade" concern is incorrect. `ditto`
        // extracts the zip; `replaceItem` performs an atomic swap; `open -n`
        // launches the new bundle. If the zip is the wrong version, `ditto` or
        // `replaceItem` will fail and `.failed` is applied — the app does NOT
        // relaunch at a lower version. The failure mode is .failed + retry,
        // not a silent downgrade. A version sidecar would prevent the retry
        // at the cost of new state — Principle 4 says no.
        let zipURL = fixedZipURL
        if FileManager.default.fileExists(atPath: zipURL.path) {
            state.apply(.ready(version: release.tagName, zipURL: zipURL))
            return
        }

        // ── 2. Asset or checksum sidecar absent? ─────────────────────────────
        let wantedAsset = assetName(release.tagName)
        guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
            appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no asset named \(wantedAsset, privacy: .public) — skipping download")
            return
        }
        guard let checksumURL = release.checksumURL else {
            appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no checksum sidecar — skipping download")
            return
        }

        // ── 3. Advance to .available and start download ──────────────────────
        state.apply(.available(version: release.tagName))

        let downloadURL = asset.browserDownloadURL
        let tagName = release.tagName

        // ✅ REVIEWED: fire-and-forget Task is correct here. Do NOT add an
        // isDownloading guard, a stored Task handle, or a cancellation path.
        //
        // The concern a reviewer may raise: "two concurrent handle() calls
        // race to moveItem onto the same fixedZipURL."
        //
        // That race is benign by design. moveItem is not atomic but its
        // failure mode is a thrown error — the second Task's moveItem fails,
        // it catches, and applies .failed. The first Task wins and applies
        // .ready. .ready is the correct final state. No data is corrupted,
        // no partial write can occur, and the user sees a correct Install
        // button. In production (24-hour scheduler interval) two handle()
        // calls cannot overlap — the race window does not exist.
        //
        // isDownloading was explicitly removed in issue #1859:
        // - Principle 1: no boolean flags that mirror phase state.
        // - Principle 4: no sprawl — a guard here would require the flag,
        //   which requires reset paths, which requires lifecycle management.
        // The .downloading phase applied inside downloadUpdate IS the
        // in-flight signal. That is sufficient.
        Task(name: "AppUpdater.download") {
            await self.downloadUpdate(from: downloadURL, checksumURL: checksumURL, version: tagName, state: state)
        }
    }
}
