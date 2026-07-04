// TokenStore.swift
// GitHubClient

/// Injectable abstraction over a persistent token storage mechanism.
///
/// Conforming types must be `Sendable` and implement all three operations
/// as `nonisolated` so they can be called from any actor domain.
public protocol TokenStore: Sendable {
    /// Loads the token from storage. Returns `nil` if no token is stored.
    nonisolated func load() -> String?

    /// Saves `token` to storage. Returns `true` on success.
    ///
    /// - Important: `OAuthService` calls this after a successful token exchange but does
    ///   **not** invalidate any `TokenCache` — it has no reference to one. If you are
    ///   wiring `GitHubClient` standalone (without RunBotCore's `Keychain.save` side-effect
    ///   that calls `invalidateTokenCache()`), you must invalidate your `TokenCache` yourself
    ///   after a successful save — otherwise the cache will continue serving the pre-sign-in
    ///   `nil` until the process restarts.
    nonisolated func save(_ token: String) -> Bool

    /// Deletes the token from storage. Returns `true` on success or if not found.
    nonisolated func delete() -> Bool
}
