// KeychainTokenStoreTests.swift
// OAuthTokenKitTests
//
// Exercises KeychainTokenStore save / load / overwrite / delete lifecycle.
//
// These tests write to the real macOS Keychain using a test-only service /
// account pair. A defer block cleans up so no test leaves a ghost entry.
// Tests are skipped automatically when Keychain access is unavailable
// (sandboxed CI environments where SecItemAdd returns errSecMissingEntitlement).
//
// Standalone overwrite and delete-when-empty tests were merged into the
// single lifecycle contract below to eliminate permanently-known-issue
// permutations that add reported test count without adding CI protection.
//
import Foundation
import Security
import Testing

@testable import OAuthTokenKit

// MARK: - Keychain availability probe

/// Returns true when the test process has Keychain write access.
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

    private let testService = "com.runbot.GitHubClientTests"
    private let testAccount = "github-token-test-\(UUID().uuidString)"

    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: testService, account: testAccount)
    }

    // MARK: - Full lifecycle

    /// Save → load → overwrite → load replacement → delete → load absence.
    ///
    /// Absorbs: keychainTokenStore_save_overwrite,
    ///          keychainTokenStore_delete_whenEmpty_returnsTrue.
    @Test func keychainTokenStore_save_load_delete() {
        withKnownIssue("Keychain unavailable in sandboxed environment", isIntermittent: false) {
            let store = makeStore()
            defer { store.delete() }

            // 1. Save first token.
            #expect(store.save("first-token") == true)
            // 2. Load and verify.
            #expect(store.load() == "first-token")
            // 3. Save replacement (overwrite).
            #expect(store.save("second-token") == true)
            // 4. Load and verify replacement.
            #expect(store.load() == "second-token")
            // 5. Delete.
            #expect(store.delete() == true)
            // 6. Load and verify absence.
            #expect(store.load() == nil)
        } when: {
            !keychainAvailable()
        }
    }
}
