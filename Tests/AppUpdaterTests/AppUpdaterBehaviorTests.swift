// AppUpdaterBehaviorTests.swift
// AppUpdater
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterBehaviorTests

/// Exercises `AppUpdater.handle` decision paths that don’t require the network.
@MainActor
@Suite("AppUpdater.handle")
struct AppUpdaterBehaviorTests {

    /// Builds an `AppUpdater` with an isolated scheduler identifier so tests
    /// never share cache state.
    private func makeUpdater(domain: String) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "RunBot.zip" },
            schedulerIdentifier: domain,
            betaChannelProvider: { false }
        )
    }

    /// Creates a `ReleaseAsset` with the given filename.
    private func makeAsset(_ name: String) throws -> ReleaseAsset {
        ReleaseAsset(
            name: name,
            browserDownloadURL: try #require(URL(string: "https://example.com/\(name)"))
        )
    }

    // MARK: - In-flight guard (second handle dropped while download runs)

    /// While a download Task is already in flight the state phase is `.downloading`.
    /// A second `handle` for the same version must not re-advance the phase to
    /// `.available` again: the zip already exists at `fixedZipURL` by the time the
    /// second call arrives, so it fast-paths directly to `.ready`.
    ///
    /// We simulate the “already cached” condition by writing a dummy file at
    /// `fixedZipURL` before calling `handle`.
    @Test func cachedZipAdvancesDirectlyToReady() async throws {
        let domain = "test.cachehit.\(UUID().uuidString)"
        let updater = makeUpdater(domain: domain)
        let state = MockUpdateState()

        // Write a dummy zip at the fixed URL to simulate a cached download.
        let zipURL = updater.fixedZipURL
        try FileManager.default.createDirectory(
            at: zipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("zip".utf8).write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let release = AvailableRelease(
            tagName: "v9.9.9",
            assets: [try makeAsset("RunBot.zip")],
            checksumURL: URL(string: "https://example.com/RunBot.zip.sha256")
        )
        await updater.handle(release, state: state)

        guard case .ready(let version) = state.currentPhase else {
            Issue.record("Expected .ready, got \(state.currentPhase)")
            return
        }
        #expect(version == "v9.9.9")
        // Exactly one phase transition: idle → ready.
        #expect(state.appliedPhases.count == 1)
    }

    // MARK: - Missing asset (no matching zip in release)

    /// A release whose assets list contains no file matching `assetName` must
    /// leave the phase at `.idle` — no phase transition at all.
    @Test func missingAssetLeavesPhaseIdle() async throws {
        let domain = "test.noasset.\(UUID().uuidString)"
        let updater = makeUpdater(domain: domain)
        let state = MockUpdateState()
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [try makeAsset("SomethingElse.zip")],
            checksumURL: nil
        )

        await updater.handle(release, state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }
}

// MARK: - AppUpdaterCheckAndHandleTests

/// Exercises `AppUpdater.checkForUpdate(betaChannel:)` in isolation using
/// `MockReleaseProvider` — no network, no disk I/O.
@MainActor
@Suite("AppUpdater.checkAndHandle")
struct AppUpdaterCheckAndHandleTests {

    private let newerTag = "v2.0.0"
    private let olderTag = "v0.9.0"
    private let currentVersion = "1.0.0"

    /// Builds an `AppUpdater` wired to `provider` with an isolated
    /// scheduler identifier.
    private func makeUpdater(
        domain: String,
        provider: some ReleaseProvider,
        betaChannel: Bool = false
    ) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: currentVersion,
            assetName: { _ in "RunBot.zip" },
            schedulerIdentifier: domain,
            betaChannelProvider: { betaChannel },
            releaseProvider: provider
        )
    }

    /// Minimal `AvailableRelease` fixture — no assets, no checksum URL.
    private func release(tag: String) -> AvailableRelease {
        AvailableRelease(tagName: tag, assets: [], checksumURL: nil)
    }

    // MARK: - 1. Provider returns nil → .failed

    @Test func providerReturnsNil_failedNoReleasesFound() async throws {
        let domain = "test.check.nil.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              checkError == .noReleasesFound else {
            Issue.record("Expected .failed(.noReleasesFound), got \(result)")
            return
        }
    }

    // MARK: - 2. Provider returns release that is NOT newer → .upToDate

    @Test func providerReturnsOlderVersion_upToDate() async throws {
        let domain = "test.check.older.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: release(tag: olderTag))
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .upToDate = result else {
            Issue.record("Expected .upToDate, got \(result)")
            return
        }
    }

    // MARK: - 3. Provider returns newer release → .updateAvailable

    @Test func providerReturnsNewerVersion_updateAvailable() async throws {
        let domain = "test.check.newer.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: release(tag: newerTag))
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .updateAvailable(let r) = result else {
            Issue.record("Expected .updateAvailable, got \(result)")
            return
        }
        #expect(r.tagName == newerTag)
    }

    // MARK: - 4. betaChannel=false forwarded to provider

    @Test func betaChannelFalse_passedToProvider() async throws {
        let domain = "test.check.beta.false.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: false)

        let captured = await provider.capturedBetaChannel
        #expect(captured == false)
    }

    // MARK: - 5. betaChannel=true forwarded to provider

    @Test func betaChannelTrue_passedToProvider() async throws {
        let domain = "test.check.beta.true.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: true)

        let captured = await provider.capturedBetaChannel
        #expect(captured == true)
    }

    // MARK: - 6. fetchLatestRelease called exactly once per checkForUpdate

    @Test func callCount_exactlyOnePerCheck() async throws {
        let domain = "test.check.callcount.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: false)

        let count = await provider.callCount
        #expect(count == 1)
    }
}
