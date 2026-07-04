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
    /// - Important: `OAuthService` calls this after a successful token exchange but holds
    ///   no reference to any `TokenCache`. If you need the cache invalidated after a save,
    ///   pass an `onTokenSaved` closure to `GitHubClient.init` — it is called automatically
    ///   after every successful `save()`. Without it the cache will continue serving the
    ///   pre-sign-in `nil` until the process restarts.
    nonisolated func save(_ token: String) -> Bool

    /// Deletes the token from storage. Returns `true` on success or if not found.
    ///
    /// - Important: Deletion is **best-effort**. `OAuthService.signOut()` always clears
    ///   the in-memory cache (`onTokenDeleted`) and emits the sign-out stream, regardless
    ///   of this return value. A `false` return is logged but does not block sign-out.
    ///
    ///   Implementations **must** return `true` when the item is already absent
    ///   (not-found is a success). Return `false` only on a genuine storage error.
    nonisolated func delete() -> Bool
}
