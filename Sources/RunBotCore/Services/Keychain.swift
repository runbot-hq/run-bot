// Keychain.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - Keychain
//
// Thin adapter over GitHubClient.KeychainTokenStore.
//
// All SecItem* logic (kSecUseDataProtectionKeychain, kSecAttrAccessibleAfterFirstUnlock,
// upsert retry guard, error logging) lives in KeychainTokenStore. This type's sole
// responsibility is bridging the RunBot-specific service/account constants and calling
// invalidateTokenCache() after mutations to keep GitHubClient.TokenCache consistent.
//
// Thread-safety: SecItem* calls are serialised by the Security framework at the OS level.
// invalidateTokenCache() is Mutex-guarded inside TokenCache. No additional locking needed.
//
// Visibility note:
// Keychain is public because SettingsView in the RunBot app target reads Keychain.token
// directly for UI state. A future refactor could route that through TokenCache.token()
// and scope this type internal. Tracked as a follow-up.

/// RunBot-specific keychain adapter.
///
/// Delegates all `SecItem*` operations to `GitHubClient.KeychainTokenStore` and
/// invalidates the in-memory `TokenCache` after every successful mutation.
public enum Keychain {

    /// The underlying `TokenStore` that owns all keychain I/O for RunBot.
    private static let store = KeychainTokenStore(
        service: "run-bot",
        account: "github-oauth-token",
        logger: RunBotLogger()
    )

    // MARK: - Public API

    /// The stored OAuth token, or `nil` if none is present.
    public static var token: String? {
        store.load()
    }

    /// Saves (or overwrites) the token and invalidates the in-memory token cache.
    /// Returns `true` if the token was successfully persisted.
    ///
    /// - Note: Error logging is handled inside `KeychainTokenStore` via `RunBotLogger`.
    @discardableResult
    public static func save(_ token: String) -> Bool {
        let succeeded = store.save(token)
        // FIXME(P24): atomicity gap — store.save() and invalidateTokenCache() are not
        // atomic. A concurrent githubToken() caller between the two calls will read the
        // stale cached value. For a menu-bar app this window is negligible.
        if succeeded { invalidateTokenCache() }
        return succeeded
    }

    /// Deletes the stored token and invalidates the in-memory token cache.
    /// Returns `true` on success or if the item was already absent.
    ///
    /// - Note: Error logging is handled inside `KeychainTokenStore` via `RunBotLogger`.
    @discardableResult
    public static func delete() -> Bool {
        let succeeded = store.delete()
        if succeeded { invalidateTokenCache() }
        return succeeded
    }
}
