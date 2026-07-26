// MockTokenStore.swift
// OAuthTokenKitTests
// In-memory `TokenStore` double for exercising OAuthService tests without touching the keychain.
import Foundation
import OAuthTokenKit
import Synchronization

// MARK: - MockTokenStore

/// In-memory `TokenStore` double. Keychain-free and safe to construct per test.
/// Backed by a `Mutex` so it is `Sendable` without `@unchecked`.
///
/// Intentionally `nonisolated` (no `@MainActor` annotation). The `Mutex`
/// provides the necessary thread safety, so this type works correctly from
/// any actor context — including `@MainActor`-isolated test suites such as
/// `OAuthServiceScopesTests` and `OAuthServiceRedirectURITests`.
///
/// This copy is owned by `OAuthTokenKitTests` and may diverge from the copy
/// in `GitHubClientTests/TestSupport/` as each target's needs evolve.
/// The two copies are intentionally independent — do not attempt to share or sync them.
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
