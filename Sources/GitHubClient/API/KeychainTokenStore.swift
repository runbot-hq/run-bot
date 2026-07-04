// KeychainTokenStore.swift
// GitHubClient

import Foundation
import Security

/// A `TokenStore` implementation backed by the macOS/iOS Keychain.
///
/// This is a general-purpose store suitable for standalone `swift-github-client` consumers.
///
/// - Warning: This implementation does **not** set `kSecUseDataProtectionKeychain` or
///   `kSecAttrAccessible`. On some macOS configurations, omitting
///   `kSecUseDataProtectionKeychain: true` causes a `CSSMERR_DL_DATASTORE_DOESNOT_EXIST`
///   crash at launch. If your host app already manages keychain access via a dedicated
///   enum or helper that sets these attributes (e.g. RunBotCore’s `Keychain`), pass a
///   `TokenStore` adapter that delegates to that helper instead of using this type directly.
public final class KeychainTokenStore: TokenStore {

    /// The keychain service name (e.g. bundle identifier).
    private let service: String
    /// The keychain account name (e.g. "github-token").
    private let account: String

    /// Creates a new `KeychainTokenStore`.
    /// - Parameters:
    ///   - service: The keychain service name (e.g. bundle identifier).
    ///   - account: The keychain account name (e.g. "github-token").
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    // MARK: - TokenStore

    /// Loads the token from the keychain. Returns `nil` if not found or on error.
    public nonisolated func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    /// Saves the token to the keychain. Returns `true` on success.
    @discardableResult
    public nonisolated func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        // Try updating an existing item first.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        // Item doesn’t exist yet — add it.
        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Deletes the token from the keychain. Returns `true` on success or if not found.
    @discardableResult
    public nonisolated func delete() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
