// Keychain.swift
// RunBotCore
import Foundation
import GitHubClient
import Security

// MARK: - Keychain
//
// Wraps Security.framework to store and retrieve the OAuth token.
// Uses SecItemUpdate/SecItemAdd (upsert pattern) with errSecDuplicateItem
// retry guard, SecItemCopyMatching, and SecItemDelete.
//
// kSecUseDataProtectionKeychain: true forces all operations through the modern
// Data Protection Keychain, bypassing the legacy CSSM-based keychain entirely.
// Without this, SecItemCopyMatching can trigger a C++ CSSMERR_DL_DATASTORE_DOESNOT_EXIST
// exception that crashes the process on launch when the legacy keychain DB file
// is missing or was created under a different signing identity.
//
// Thread-safety / P16 rationale:
// SecItem* calls are serialised by the Security framework at the OS level and
// are documented as safe to call concurrently from multiple threads. No
// additional actor or lock is needed around the SecItem* calls themselves.
//
// The one piece of mutable shared state — the in-memory token cache — lives in
// GitHubClient's TokenCache.swift and is guarded by a Synchronization.Mutex.
// invalidateTokenCache() (called after every mutation here) clears that cache
// under the lock, so there is no unprotected shared mutable state in this type.
//
// Conclusion: a KeychainActor would require all call-sites to become async with
// no correctness benefit. The current design satisfies P16.
//
// Visibility note:
// Keychain is public because OAuthService and SettingsView in the RunBot
// app target call Keychain.save(), .delete(), and .token directly. A future
// refactor should route those call-sites through a dedicated public function
// boundary (e.g. keychainSave/keychainDelete in TokenCache.swift) so
// Keychain can be scoped internal. Tracked as a follow-up to this PR.

/// Wrapper around Security.framework for storing and retrieving the GitHub OAuth token.
///
/// ## Thread safety
/// `SecItem*` calls are OS-serialised by the Security framework and are safe to
/// call concurrently. The in-memory token cache is protected by
/// `Synchronization.Mutex` in `GitHubClient.TokenCache`; `invalidateTokenCache()`
/// is called after every mutation to keep it consistent. No actor wrapper is
/// required — see the file-level comment for the full P16 rationale.
public enum Keychain {
    /// Keychain service name used for RunBot credentials.
    private static let service = "run-bot"
    /// Keychain account name used for the stored OAuth token.
    private static let account = "github-oauth-token"

    // MARK: - Private helpers

    /// Returns the base Keychain query shared by all token operations.
    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    // MARK: - Public API

    /// The stored OAuth token, or nil if none is present.
    ///
    /// - Note: `SecItem*` calls are OS-serialised by the Security framework.
    ///   No actor or lock is required. See file-level P16 rationale.
    public static var token: String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token.isEmpty ? nil : token
    }

    /// Saves (or overwrites) the token and invalidates the in-memory token cache.
    /// Returns true if the token was successfully persisted.
    ///
    /// - Note: `SecItemUpdate`/`SecItemAdd` are OS-serialised.
    ///   Concurrent writers are handled by the upsert retry guard below.
    ///   See file-level P16 rationale.
    @discardableResult
    public static func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        // Try update first; fall back to add if item does not exist.
        // kSecAttrAccessibleAfterFirstUnlock is included on both paths so that a
        // legacy item created without this attribute (e.g. from an older build or
        // different signing identity) is upgraded in place. Without it, the existing
        // accessibility attribute is preserved, and a legacy item may be inaccessible
        // at launch before the first device unlock.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ] as CFDictionary
        )
        var succeeded = updateStatus == errSecSuccess
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            // kSecAttrAccessibleAfterFirstUnlock: token is readable after the first
            // unlock post-reboot, which covers app launch in the background before
            // the user has unlocked the screen. Without this, the default
            // kSecAttrAccessibleWhenUnlocked would block token reads at launch.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // A concurrent writer inserted the item between our update and add.
                // Retry the update now that the item exists.
                let retryStatus = SecItemUpdate(
                    baseQuery() as CFDictionary,
                    [
                        kSecValueData as String: data,
                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                    ] as CFDictionary
                )
                if retryStatus == errSecSuccess {
                    succeeded = true
                } else {
                    log("Keychain.save › retry SecItemUpdate failed: \(retryStatus)", category: .services)
                }
            } else if addStatus == errSecSuccess {
                succeeded = true
            } else {
                log("Keychain.save › SecItemAdd failed: \(addStatus)", category: .services)
            }
        } else if !succeeded {
            log("Keychain.save › SecItemUpdate failed: \(updateStatus)", category: .services)
        }
        // FIXME(P24): atomicity gap — SecItemUpdate/Add and invalidateTokenCache() are
        // not atomic. A concurrent githubToken() caller between the two calls will read
        // the stale cached value. For a menu-bar app this window is negligible, but a
        // future improvement could wrap both in a single Mutex-guarded operation.
        if succeeded { invalidateTokenCache() }
        return succeeded
    }

    /// Deletes the stored token.
    /// Invalidates the in-memory token cache only when deletion actually succeeds
    /// (or the item was already absent). Returns true on success.
    ///
    /// - Note: `SecItemDelete` is OS-serialised. See file-level P16 rationale.
    @discardableResult
    public static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        let succeeded = status == errSecSuccess || status == errSecItemNotFound
        if !succeeded {
            log("Keychain.delete › SecItemDelete failed: \(status)", category: .services)
            return false
        }
        invalidateTokenCache()
        return true
    }
}
