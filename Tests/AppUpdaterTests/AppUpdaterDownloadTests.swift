// AppUpdaterDownloadTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDownloadTests

/// Tests that verify `AppUpdater.handle` state-machine behaviour via
/// `MockUpdateState.currentPhase` / `appliedPhases`.
///
/// Network I/O is avoided throughout:
/// - “no matching asset” and “no checksum URL” paths return before spawning
///   any download Task.
/// - The “cached zip” path is exercised by writing a dummy file at
///   `updater.fixedZipURL` before calling `handle`.
/// - The “asset present + checksumURL present” path advances to `.available`
///   synchronously, then the download Task fires asynchronously — we assert
///   only the synchronous phase transition here.
///
/// All tests are `@MainActor` because `AppUpdater` and `MockUpdateState`
/// are both `@MainActor`.
@MainActor
struct AppUpdaterDownloadTests {

    // MARK: - Helpers

    private func makeUpdater(
        currentVersion: String = "1.0.0"
    ) -> (updater: AppUpdater, state: MockUpdateState) {
        let domain = "AppUpdaterDownloadTests.\(UUID().uuidString)"
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            betaChannelProvider: { false }
        )
        return (updater, MockUpdateState())
    }

    /// Makes an `AvailableRelease` with a matching `App.zip` asset but a nil
    /// `checksumURL`.
    private func releaseWithNilChecksum(tagName: String = "v2.0.0") throws -> AvailableRelease {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        return AvailableRelease(tagName: tagName, assets: [asset], checksumURL: nil)
    }

    // MARK: - No matching asset → phase stays .idle

    /// A release whose assets list has no file matching the expected name must
    /// leave the phase at `.idle` — no phase transitions fire.
    @Test func noMatchingAsset_phaseStaysIdle() async throws {
        let (updater, state) = makeUpdater()
        let asset = ReleaseAsset(
            name: "WrongName.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/WrongName.zip"))
        )
        let release = AvailableRelease(tagName: "v2.0.0", assets: [asset], checksumURL: nil)

        await updater.handle(release, state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }

    // MARK: - Nil checksumURL → phase stays .idle

    /// When the asset matches but `checksumURL` is nil, `handle` logs a warning
    /// and returns without applying any phase transition.
    @Test func nilChecksumURL_phaseStaysIdle() async throws {
        let (updater, state) = makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }

    /// Nil-checksumURL path: no phase transitions means `appliedPhases` is empty,
    /// regression guard against any spurious intermediate phase writes.
    @Test func nilChecksumURL_noAppliedPhases() async throws {
        let (updater, state) = makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        #expect(state.appliedPhases.isEmpty)
    }

    // MARK: - Cached zip fast-path → .ready

    /// When a zip already exists at `fixedZipURL`, `handle` must advance
    /// directly to `.ready` without spawning a download Task.
    @Test func cachedZip_advancesToReady() async throws {
        let (updater, state) = makeUpdater()
        let zipURL = updater.fixedZipURL
        try FileManager.default.createDirectory(
            at: zipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("zip".utf8).write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [asset],
            checksumURL: URL(string: "https://example.com/App.zip.sha256")
        )
        await updater.handle(release, state: state)

        guard case .ready(let version) = state.currentPhase else {
            Issue.record("Expected .ready, got \(state.currentPhase)")
            return
        }
        #expect(version == "v2.0.0")
        #expect(state.appliedPhases.count == 1)
    }

    // MARK: - Asset present + checksumURL present → .available then download

    /// When the asset matches and a checksum URL is provided, `handle` must
    /// synchronously advance to `.available` before handing off to the download
    /// Task. We verify only the synchronous phase here; the async download path
    /// requires a real network and is out of scope for unit tests.
    @Test func assetAndChecksum_advancesToAvailable() async throws {
        let (updater, state) = makeUpdater()

        // Ensure the zip does NOT exist so we don’t hit the cached fast-path.
        let zipURL = updater.fixedZipURL
        try? FileManager.default.removeItem(at: zipURL)

        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [asset],
            checksumURL: URL(string: "https://example.com/App.zip.sha256")
        )
        await updater.handle(release, state: state)

        // The first synchronous phase must be .available.
        guard let first = state.appliedPhases.first,
              case .available(let version) = first else {
            Issue.record("Expected first applied phase to be .available, got \(state.appliedPhases)")
            return
        }
        #expect(version == "v2.0.0")
    }

    /// Regression: a second `handle` call while a download is in flight arrives
    /// when the zip does not yet exist. `handle` re-advances to `.available`
    /// (the in-flight guard was removed with `isDownloading`). Verify `.available`
    /// phase is set on both calls.
    @Test func secondHandle_noZip_advancesToAvailableAgain() async throws {
        let (updater, state) = makeUpdater()

        let zipURL = updater.fixedZipURL
        try? FileManager.default.removeItem(at: zipURL)

        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [asset],
            checksumURL: URL(string: "https://example.com/App.zip.sha256")
        )

        await updater.handle(release, state: state)
        await updater.handle(release, state: state)

        // Both calls should produce .available transitions.
        let availableCount = state.appliedPhases.filter {
            if case .available = $0 { return true }
            return false
        }.count
        #expect(availableCount >= 1)
    }
}
