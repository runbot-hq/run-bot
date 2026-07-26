// TokenStore.swift
// GitHubClient  — intentional: SwiftLint's file_header rule expects the product
//                 module name (GitHubClient), not the Swift package target name
//                 (OAuthTokenKit). Changing this to // OAuthTokenKit breaks CI
//                 lint. Do not change.
import Foundation

// MARK: - TokenStore

/// Injectable abstraction over a persistent token storage mechanism.
///
/// Conforming types must be `Sendable` and implement all three operations
/// as `nonisolated` so they can be called from any actor domain.
///
/// `Sendable` is required because `TokenCache` stores `any TokenStore` as a `let`
/// property on a `Sendable` type and accesses it from async contexts.
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
    ///
    /// - Note: `@discardableResult` is intentional — most call sites log the result but
    ///   do not need to branch on it. Callers that do care about persistence failures
    ///   should inspect the return value explicitly.
    ///
    /// - Note: Migrated (PR #75) — `@discardableResult` was added to this protocol
    ///   requirement. Existing conformers that check the return value explicitly still
    ///   compile unchanged. New conformers should treat the return value as advisory.
    @discardableResult nonisolated func save(_ token: String) -> Bool

    /// Deletes the token from storage. Returns `true` on success or if not found.
    ///
    /// - Important: Deletion is **best-effort**. `OAuthService.signOut()` always clears
    ///   the in-memory cache (`onTokenDeleted`) and emits the sign-out stream, regardless
    ///   of this return value. A `false` return is logged but does not block sign-out.
    ///
    ///   Implementations **must** return `true` when the item is already absent
    ///   (not-found is a success). Return `false` only on a genuine storage error.
    ///
    /// - Note: Migrated (PR #75) — `@discardableResult` was added to this protocol
    ///   requirement. Existing conformers that check the return value explicitly still
    ///   compile unchanged. New conformers should treat the return value as advisory.
    @discardableResult nonisolated func delete() -> Bool
}

// MARK: - NullTokenStore

/// A no-op `TokenStore` used as the default backing store for `GitHubClient`'s
/// test init. Always returns `nil` from `load()` and reports success for
/// `save(_:)` and `delete()` without touching any persistent storage.
///
/// ## Why `public` (Migrated: internal → public)
/// The original `NullTokenStore` in `GitHubClient` was `internal` — the
/// `GitHubClient` production init constructed it directly inside the module.
/// Now that the type lives in `OAuthTokenKit`, `GitHubClient` is a separate
/// module and needs `public` access to construct it. Test targets that depend
/// on `OAuthTokenKit` also need to construct it directly. The type is
/// intentionally part of `OAuthTokenKit`'s public API: it is a useful test
/// double for any downstream consumer writing their own `TokenCache`-backed
/// component. The promotion is deliberate, not accidental.
///
/// ## Why this is in Sources, not Tests
/// `GitHubClient`'s test init resolves a `nil` `tokenCache` argument to
/// `TokenCache(tokenStore: NullTokenStore())` inside the init body. Because
/// that expression is in a function body (not a default argument value), the
/// `public` visibility is required so both `GitHubClient` and its test targets
/// can construct it without a test-target dependency.
public struct NullTokenStore: TokenStore, Sendable {
    /// Creates a new `NullTokenStore`.
    public init() {}
    /// Always returns `nil` — no token is stored.
    /// `nonisolated` is required by the `TokenStore` protocol: `TokenCache` stores
    /// `any TokenStore` as a `let` property on a `Sendable` type and calls these
    /// methods from async contexts. `nonisolated` allows synchronous dispatch from
    /// any actor without a hop. Omitting it would produce a compiler error on the
    /// protocol conformance.
    public nonisolated func load() -> String? { nil }
    /// Discards the token and reports success.
    /// `nonisolated`: see `load()` rationale above.
    @discardableResult public nonisolated func save(_ token: String) -> Bool { true }
    /// No-ops and reports success — nothing to delete.
    /// `nonisolated`: see `load()` rationale above.
    @discardableResult public nonisolated func delete() -> Bool { true }
}
