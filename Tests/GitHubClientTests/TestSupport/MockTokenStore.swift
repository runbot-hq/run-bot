// MockTokenStore.swift
// GitHubClientTests
// In-memory `TokenStore` double for exercising `TokenCache` without touching the keychain.
import Foundation
import GitHubClient
import Synchronization

// MARK: - MockTokenStore

/// In-memory `TokenStore` double. Keychain-free and safe to construct per test.
/// Backed by a `Mutex` so it is `Sendable` without `@unchecked`.
final class MockTokenStore: TokenStore {
    private let storage: Mutex<String?>

    /// Creates a store seeded with an optional initial token.
    init(initial: String? = nil) {
        storage = Mutex<String?>(initial)
    }

    func load() -> String? {
        storage.withLock { $0 }
    }

    func save(_ token: String) -> Bool {
        storage.withLock { $0 = token }
        return true
    }

    func delete() -> Bool {
        storage.withLock { $0 = nil }
        return true
    }
}
