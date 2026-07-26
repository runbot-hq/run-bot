// KeychainTokenStoreTests.swift
// OAuthTokenKitTests
//
// Exercises `KeychainTokenStore` save / load / delete round-trip.
//
// ⚠️ KEYCHAIN SIDE-EFFECTS
// These tests write to the real macOS Keychain using a test-only service /
// account pair. A `defer` block in every test cleans up the item so no test
// leaves a ghost entry. The tests require access to the Data Protection
// Keychain and will be skipped automatically in sandboxed environments
// where `SecItemAdd` returns `errSecMissingEntitlement`.
//
// Running locally: `swift test` on macOS 15+ is sufficient.
// CI: the macOS runner on GitHub Actions has keychain access by default;
// `errSecMissingEntitlement` is not expected on the standard `macos-26`
// runner image.

import Foundation
import Security
import Testing

@testable import OAuthTokenKit

// MARK: - Keychain availability probe

/// Returns true when the test process has Keychain write access.
/// Uses a throwaway item under the test service to avoid touching production items.
private func keychainAvailable() -> Bool {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.runbot.GitHubClientTests.probe",
        kSecAttrAccount: "probe",
        kSecUseDataProtectionKeychain: true,
        kSecValueData: Data("x".utf8)
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecSuccess || status == errSecDuplicateItem {
        SecItemDelete(query as CFDictionary)
        return true
    }
    return false
}

// MARK: - KeychainTokenStoreTests

@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {

    /// Unique service / account pair used by these tests.
    ///
    /// Using a distinct account name avoids collisions with any real
    /// app credential that happens to share the bundle-style service name.
    private let testService = "com.runbot.GitHubClientTests"
    private let testAccount = "github-token-test-\(UUID().uuidString)"

    /// Builds a fresh `KeychainTokenStore` backed by the test service/account.
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: testService, account: testAccount)
    }

    // MARK: - save / load / delete round-trip

    /// Saves a token, reads it back, then deletes it.
    @Test func keychainTokenStore_save_load_delete() {
        withKnownIssue("Keychain unavailable in sandboxed environment", isIntermittent: false) {
            let store = makeStore()
            defer { store.delete() }

            #expect(store.load() == nil)
            #expect(store.save("test-oauth-token-abc123") == true)
            #expect(store.load() == "test-oauth-token-abc123")
            #expect(store.delete() == true)
            #expect(store.load() == nil)
        } when: {
            !keychainAvailable()
        }
    }

    /// Overwrites an existing token with a new value.
    @Test func keychainTokenStore_save_overwrite() {
        withKnownIssue("Keychain unavailable in sandboxed environment", isIntermittent: false) {
            let store = makeStore()
            defer { store.delete() }

            #expect(store.save("first-token") == true)
            #expect(store.save("second-token") == true)
            #expect(store.load() == "second-token")
        } when: {
            !keychainAvailable()
        }
    }

    /// `delete()` is idempotent — calling it when no item exists returns `true`.
    @Test func keychainTokenStore_delete_whenEmpty_returnsTrue() {
        withKnownIssue("Keychain unavailable in sandboxed environment", isIntermittent: false) {
            let store = makeStore()
            #expect(store.delete() == true)
        } when: {
            !keychainAvailable()
        }
    }
}
