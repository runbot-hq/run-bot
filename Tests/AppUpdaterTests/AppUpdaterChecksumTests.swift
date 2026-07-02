// AppUpdaterChecksumTests.swift
// AppUpdaterTests
import CryptoKit
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterChecksumTests

/// Tests for `verifyChecksum` (a free function) and
/// `AppUpdater.fixedZipURL`.
///
/// Both verifyChecksum and fixedZipURL require no network.
@MainActor
struct AppUpdaterChecksumTests {

    // MARK: - Helpers

    private func makeUpdater() -> AppUpdater {
        let domain = "AppUpdaterChecksumTests.\(UUID().uuidString)"
        return AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain
        )
    }

    /// Writes `contents` to a temp file and returns the URL. Caller owns cleanup.
    private func writeTempFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-\(UUID().uuidString).zip")
        try contents.write(to: url)
        return url
    }

    /// Computes the lowercase SHA-256 hex digest of `data`.
    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - verifyChecksum — matching digest

    @Test func verifyChecksum_matchingDigest_doesNotThrow() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let expectedHex = sha256Hex(payload)
        // Must not throw
        try await verifyChecksum(zipURL: url, expectedHex: expectedHex)
    }

    // MARK: - verifyChecksum — mismatched digest

    @Test func verifyChecksum_mismatchedDigest_throwsCannotDecodeContentData() async throws {
        let payload = Data("original content".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let wrongHex = sha256Hex(Data("different content".utf8))
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: wrongHex)
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    @Test func verifyChecksum_emptyExpectedHex_throwsOnAnyNonEmptyFile() async throws {
        let url = try writeTempFile(Data("any content".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: "")
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
    }

    // MARK: - verifyChecksum — missing file

    @Test func verifyChecksum_missingFile_throwsError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).zip")
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: "abc123")
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
    }

    // MARK: - fixedZipURL

    @Test func fixedZipURL_filenameIsUpdateZip() {
        let updater = makeUpdater()
        #expect(updater.fixedZipURL.lastPathComponent == "update.zip")
    }

    @Test func fixedZipURL_extensionIsZip() {
        let updater = makeUpdater()
        #expect(updater.fixedZipURL.pathExtension == "zip")
    }

    @Test func fixedZipURL_scopedToSchedulerIdentifier() {
        let updater = makeUpdater()
        let parentDir = updater.fixedZipURL.deletingLastPathComponent().lastPathComponent
        #expect(parentDir == updater.schedulerIdentifier)
    }

    @Test func fixedZipURL_differentIdentifiers_differentPaths() {
        let updaterA = AppUpdater(
            repo: "o/r", currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.a"
        )
        let updaterB = AppUpdater(
            repo: "o/r", currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.b"
        )
        #expect(updaterA.fixedZipURL != updaterB.fixedZipURL)
    }
}
