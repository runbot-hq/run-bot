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
    nonisolated func save(_ token: String) -> Bool
    /// Deletes the token from storage. Returns `true` on success or if not found.
    nonisolated func delete() -> Bool
}
