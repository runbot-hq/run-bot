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
///   avoiding the legacy CSSM-based keychain and its associated
///   `CSSMERR_DL_DATASTORE_DOESNOT_EXIST` crash on some macOS configurations.
/// - Makes the token readable after the first unlock post-reboot, covering
///   app launch in the background before the user has unlocked the screen.
///
/// ## Thread safety
/// `SecItem*` calls are serialised by the Security framework at the OS level
/// and are safe to call concurrently from multiple threads without additional
/// locking. All stored properties are immutable (`let`), and `GitHubLogger`
/// requires `Sendable` conformance, so `KeychainTokenStore` satisfies `Sendable`
/// without any `@unchecked` escape hatch (P4).
///
/// ## Usage
/// Pass an instance at `OAuthService` / `TokenCache` init time:
/// ```swift
/// let store = KeychainTokenStore(
///     service: "com.example.myapp",
///     account: "github-token",
///     logger: MyLogger()
/// )
/// let tokenCache = TokenCache(tokenStore: store, logger: MyLogger())
/// ```
public final class KeychainTokenStore: TokenStore, Sendable {

    /// The keychain service name (e.g. bundle identifier).
    private let service: String
    /// The keychain account name (e.g. `"github-token"`).
    private let account: String
    /// Optional logger for diagnostic and error messages.
    private let logger: (any GitHubLogger)?

    /// Creates a new `KeychainTokenStore`.
    /// - Parameters:
    ///   - service: The keychain service name (e.g. bundle identifier).
    ///   - account: The keychain account name (e.g. `"github-token"`).
    ///   - logger: Optional logger for diagnostic messages.
    public init(service: String, account: String, logger: (any GitHubLogger)? = nil) {
        self.service = service
        self.account = account
        self.logger = logger
    }

    // MARK: - Private helpers

    /// Base keychain query shared by all operations.
    ///
    /// `kSecUseDataProtectionKeychain: true` routes all calls through the modern
    /// Data Protection Keychain, bypassing the legacy CSSM-based keychain entirely.
    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
    }

    // MARK: - TokenStore

    /// Loads the token from the keychain. Returns `nil` if not found or on error.
    public nonisolated func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
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
                logger?.log(
                    "KeychainTokenStore › save: retry update failed (\(retryStatus))",
                    category: "transport")
                return false
            }
            logger?.log(
                "KeychainTokenStore › save: SecItemAdd failed (\(addStatus))",
                category: "transport")
            return false
        }
        logger?.log(
            "KeychainTokenStore › save: SecItemUpdate failed (\(updateStatus))",
            category: "transport")
        return false
    }

    /// Deletes the token from the keychain. Returns `true` on success or if not found.
    @discardableResult
    public nonisolated func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        logger?.log(
            "KeychainTokenStore › delete: SecItemDelete failed (\(status))",
            category: "transport")
        return false
    }
}
