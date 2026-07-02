// AppUpdaterFetchTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterFetchTests

/// Tests that verify `AppUpdater.checkAndHandle` drives host state correctly
/// based on what `MockReleaseProvider` returns.
///
/// Zero `DispatchQueue` usage (Pillar 5). All tests run on `@MainActor`
/// because `AppUpdater` and `MockUpdateState` are both `@MainActor`.
@MainActor
struct AppUpdaterFetchTests {

    // MARK: - Helpers

    private func makeStack(
        currentVersion: String = "1.0.0",
        betaChannel: Bool = false
    ) -> (updater: AppUpdater, provider: MockReleaseProvider, state: MockUpdateState) {
        let provider = MockReleaseProvider()
        let state = MockUpdateState()
        let domain = "AppUpdaterFetchTests.\(UUID().uuidString)"
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            betaChannelProvider: { betaChannel },
            releaseProvider: provider
        )
        return (updater, provider, state)
    }

    /// Builds an `AvailableRelease` with a matching `App.zip` asset **and** a
    /// real `checksumURL` (pointing at a `.sha256` sidecar).
    ///
    /// `handle()` guards on `release.checksumURL != nil` before applying any
    /// phase — a nil checksum causes an early return with no state transition,
    /// which would silently break every test that expects `.available`.
    private func makeRelease(
        tagName: String = "v2.0.0"
    ) throws -> AvailableRelease {
        let base = "https://example.com"
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "\(base)/App.zip"))
        )
        let checksumAsset = ReleaseAsset(
            name: "App.zip.sha256",
            browserDownloadURL: try #require(URL(string: "\(base)/App.zip.sha256"))
        )
        return AvailableRelease(
            tagName: tagName,
            assets: [asset, checksumAsset],
            checksumURL: checksumAsset.browserDownloadURL
        )
    }

    // MARK: - Tests

    @Test func checkAndHandle_updateAvailable_appliesAvailablePhase() async throws {
        let (updater, provider, state) = makeStack()
        await provider.set(releaseToReturn: try makeRelease())
        await updater.checkAndHandle(state: state)
        // At minimum the .available phase must have been applied.
        let hasAvailable = state.appliedPhases.contains {
            if case .available = $0 { return true }
            return false
        }
        #expect(hasAvailable)
    }

    @Test func checkAndHandle_upToDate_noPhaseTransition() async throws {
        // Provider returns the same version as currentVersion → .upToDate
        let (updater, provider, state) = makeStack(currentVersion: "2.0.0")
        await provider.set(releaseToReturn: try makeRelease(tagName: "v2.0.0"))
        await updater.checkAndHandle(state: state)
        #expect(state.appliedPhases.isEmpty)
    }

    @Test func checkAndHandle_nilRelease_noPhaseTransition() async throws {
        let (updater, _, state) = makeStack()
        // Default releaseToReturn is nil — no phase transitions expected.
        await updater.checkAndHandle(state: state)
        #expect(state.appliedPhases.isEmpty)
    }

    @Test func checkAndHandle_betaOff_capturedBetaChannelIsFalse() async throws {
        let (updater, provider, state) = makeStack(betaChannel: false)
        await provider.set(releaseToReturn: nil)
        await updater.checkAndHandle(state: state)
        let captured = await provider.capturedBetaChannel
        #expect(captured == false)
        _ = state
    }

    @Test func checkAndHandle_betaOn_capturedBetaChannelIsTrue() async throws {
        let (updater, provider, state) = makeStack(betaChannel: true)
        await provider.set(releaseToReturn: try makeRelease(tagName: "v2.0.0-beta.1"))
        await updater.checkAndHandle(state: state)
        let captured = await provider.capturedBetaChannel
        #expect(captured == true)
        let hasAvailable = state.appliedPhases.contains {
            if case .available = $0 { return true }
            return false
        }
        #expect(hasAvailable)
    }

    @Test func checkAndHandle_fetchCallCount_exactlyOne() async throws {
        let (updater, provider, state) = makeStack()
        await updater.checkAndHandle(state: state)
        let count = await provider.fetchCallCount
        #expect(count == 1)
        _ = state
    }
}
