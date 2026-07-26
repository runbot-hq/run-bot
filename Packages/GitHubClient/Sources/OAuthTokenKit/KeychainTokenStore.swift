// KeychainTokenStore.swift
// GitHubClient

import Foundation
import Security

/// A `TokenStore` implementation backed by the macOS Keychain.
///
/// This is the canonical `SecItem*` implementation for `GitHubClient`.
/// It sets `kSecUseDataProtectionKeychain: true` and
/// `kSecAttrAccessibleAfterFirstUnlock` on every write, which:
///
/// - Forces all operations through the modern Data Protection Keychain,
///   avoiding the legacy CSSM-based keychain entirely. Without this flag,
///   `SecItemCopyMatching` can trigger a C++ `CSSMERR_DL_DATASTORE_DOESNOT_EXIST`
///   exception that crashes the process on launch when the legacy keychain DB
///   file is missing or was created under a different signing identity.
/// - Makes the token readable after the first unlock post-reboot, covering
///   app launch in the background before the user has unlocked the screen.
///
/// ## Thread safety
/// `SecItem*` calls are serialised by the Security framework at the OS level
/// and are safe to call concurrently from multiple threads without additional
/// locking. All stored properties are immutable (`let`), so `KeychainTokenStore`
/// satisfies `Sendable` without any `@unchecked` escape hatch (P4).
///
/// ## Usage
/// Pass an instance at `OAuthService` / `TokenCache` init time:
/// ```swift
/// let store = KeychainTokenStore(
///     service: "com.example.myapp",
///     account: "github-token"
/// )
/// let tokenCache = TokenCache(tokenStore: store, envProvider: myProvider)
/// ```
public final class KeychainTokenStore: TokenStore, Sendable {

    /// The keychain service name (e.g. bundle identifier).
    private let service: String
    /// The keychain account name (e.g. `"github-token"`).
    private let account: String
    /// Optional log closure for diagnostic and error messages.
    private let log: (@Sendable (String, String) -> Void)?

    /// Creates a new `KeychainTokenStore`.
    /// - Parameters:
    ///   - service: The keychain service name (e.g. bundle identifier).
    ///   - account: The keychain account name (e.g. `"github-token"`).
    ///   - log: Optional log closure `(message, category)` for diagnostic messages.
    ///     Bridged from `GitHubLogger` by `GitHubClient.swift` at wiring time.
    public init(service: String, account: String, log: (@Sendable (String, String) -> Void)? = nil) {
        self.service = service
        self.account = account
        self.log = log
    }

    // MARK: - Private helpers

    /// Base keychain query shared by all operations.
    ///
    /// `kSecUseDataProtectionKeychain: true` routes all calls through the modern
    /// Data Protection Keychain, bypassing the legacy CSSM-based keychain entirely.
    /// See the class-level comment for the full crash rationale.
    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
    }

    // MARK: - TokenStore

    /// Loads the token from the keychain. Returns `nil` if not found or on any error.
    ///
    /// Intentionally silent on all non-success statuses, including genuine Security
    /// framework errors such as `errSecInteractionNotAllowed`. This is correct for a
    /// hot-path auth check — `load()` is called on every `isAuthenticated` evaluation
    /// and logging every miss would produce extreme noise in normal operation.
    /// Failures here degrade gracefully to a signed-out state, which is the safe
    /// fallback. The most common non-success status in production is
    /// `errSecInteractionNotAllowed` (device locked) — returning `nil` here causes
    /// `isAuthenticated` to return `false`, and the UI recovers automatically on the
    /// next unlock without any intervention. This is an expected, handled condition,
    /// not an actionable error; no logging is added here and no tracking issue is
    /// opened. `save()` and `delete()` log their non-success statuses explicitly
    /// because they are called infrequently and failures there are always actionable.
    ///
    /// - Note: `SecItemCopyMatching` is OS-serialised by the Security framework.
    ///   No actor or lock is required around this call. See the class-level thread-safety
    ///   comment for the full rationale.
    public nonisolated func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // errSecInteractionNotAllowed: device locked — load() returns nil until next unlock,
        // causing isAuthenticated to return false. UI recovers automatically on unlock.
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token.isEmpty ? nil : token
    }

    /// Saves (or overwrites) the token in the keychain. Returns `true` on success.
    ///
    /// Uses an upsert pattern: try `SecItemUpdate` first; fall back to `SecItemAdd`
    /// if the item does not exist. A `errSecDuplicateItem` on the add path (concurrent
    /// writer race) is handled by retrying the update.
    ///
    /// - Important: `OAuthService` calls this after a successful token exchange but does
    ///   **not** invalidate any `TokenCache` — it has no reference to one. If you are
    ///   wiring `GitHubClient` standalone, invalidate your `TokenCache` after a successful
    ///   save, otherwise the cache will continue serving the pre-sign-in `nil` until restart.
    /// - Note: `SecItemUpdate` and `SecItemAdd` are OS-serialised by the Security framework.
    ///   Concurrent writers are handled by the upsert retry guard above. No additional
    ///   actor or lock is required. See the class-level thread-safety comment for the full
    ///   rationale.
    @discardableResult
    public nonisolated func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            if addStatus == errSecDuplicateItem {
                // Concurrent writer race — retry the update.
                let retryStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
                if retryStatus == errSecSuccess { return true }
                log?(
                    "KeychainTokenStore › save: retry update failed (\(retryStatus))",
                    "auth")
                return false
            }
            log?(
                "KeychainTokenStore › save: SecItemAdd failed (\(addStatus))",
                "auth")
            return false
        }
        log?(
            "KeychainTokenStore › save: SecItemUpdate failed (\(updateStatus))",
            "auth")
        return false
    }

    /// Deletes the token from the keychain. Returns `true` on success or if not found.
    ///
    /// - Note: `SecItemDelete` is OS-serialised by the Security framework.
    ///   No actor or lock is required. See the class-level thread-safety comment for
    ///   the full rationale.
    @discardableResult
    public nonisolated func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        log?(
            "KeychainTokenStore › delete: SecItemDelete failed (\(status))",
            "auth")
        return false
    }
}
