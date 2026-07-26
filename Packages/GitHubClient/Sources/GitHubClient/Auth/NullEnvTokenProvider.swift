// NullEnvTokenProvider.swift
// GitHubClient

import EnvTokenKit

// MARK: - NullEnvTokenProvider

/// A no-op `EnvTokenProviding` implementation that always returns `nil` from
/// `token()` and does nothing in `invalidate()`.
///
/// ## Role: null-object for the env-provider slot
/// `TokenCache` stores `any EnvTokenProviding` as a non-optional field.
/// Making it optional would add a nil-check on every `token()` and
/// `invalidate()` call across the production path — just to handle the
/// cases where env resolution is not needed. `NullEnvTokenProvider` follows
/// the null-object pattern instead: callers that have no env source inject
/// this type explicitly, keeping the hot path clean.
///
/// ## When it is used
/// `TokenCache.init(tokenStore:)` — the convenience init — stores
/// `NullEnvTokenProvider()` automatically. That init is called from
/// `GitHubClient.init(oauthService:transport:tokenCache:)` when `tokenCache`
/// is `nil`. Despite the parameter names, that init is `public` and is used
/// in production builds wherever a fully-wired `GitHubClient` is not needed:
///
/// - **SwiftUI previews** — inject a `MockOAuthService` and `MockTransport`
///   without touching the Keychain or spawning a login shell.
/// - **Demo / sandbox apps** — same pattern.
/// - **Unit and integration tests** — the most common caller.
///
/// The production init (`GitHubClient.init(clientID:clientSecret:…)`) always
/// injects a real `EnvTokenProvider` via the primary `TokenCache` init and
/// never reaches this type.
///
/// ## Why internal, not public
/// `NullEnvTokenProvider` is constructed internally by `TokenCache.init(tokenStore:)`.
/// No downstream caller ever names this type directly — they get it implicitly
/// by omitting the `tokenCache:` parameter on `GitHubClient`'s mock init.
/// Keeping it `internal` prevents it from leaking into the public API surface.
///
/// ## Sendable
/// Explicitly conforms to `Sendable` (in addition to the synthesis from
/// `EnvTokenProviding: Sendable`). Zero stored properties means the compiler
/// synthesises this correctly, but the explicit declaration makes the intent
/// clear: this type is designed for injection into a `Mutex`-guarded
/// `any EnvTokenProviding` slot. If a stored property is ever added (e.g. a
/// `callCount` spy), an explicit `Sendable` conformance requires that property
/// to also be `Sendable` — producing a compiler error rather than a silent
/// data-race regression.
struct NullEnvTokenProvider: EnvTokenProviding, Sendable {
    /// Always returns `nil` — no env-var read or shell subprocess is performed.
    func token() async -> String? { nil }
    /// No-op — there is no shell outcome latch or cached state to reset.
    nonisolated func invalidate() {}
}
