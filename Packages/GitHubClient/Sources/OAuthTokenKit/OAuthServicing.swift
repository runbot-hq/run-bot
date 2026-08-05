// OAuthServicing.swift
// GitHubClient
import Foundation

// MARK: - OAuthServiceProtocol

/// Abstraction over the GitHub OAuth Authorization Code flow.
///
/// `@MainActor` isolation mirrors the concrete `OAuthService` — all methods are
/// serialised on the main thread because:
/// - `handleCallback(_:)` is delivered by `AppDelegate.application(_:open:)` on the main thread.
/// - `makeSignInStream()` is consumed by `OAuthCredentialController`,
///   which runs on `@MainActor`.
///
/// `AnyObject` constraint is required because the protocol has settable state.
/// Mutating stored properties requires reference semantics — structs cannot adopt this protocol.
///
/// ## Warning to nonisolated conformers
/// `OAuthService.envVarIsSet(_:)` calls `getenv()` and relies on `@MainActor`
/// serialisation for thread safety. A conformer that declares its implementation
/// `nonisolated` — or drops `@MainActor` from the protocol — silently removes
/// that guarantee. Swift provides no compile-time enforcement of this assumption
/// at the protocol boundary. Any new conformer that is not `@MainActor` must
/// either avoid `getenv()` or provide its own synchronisation for env-var reads.
///
/// ## Production usage
/// ```swift
/// let oauthService: any OAuthServiceProtocol = OAuthService()
/// ```
///
/// ## Test double
/// ```swift
/// @MainActor
/// final class StubOAuthService: OAuthServiceProtocol {
///     var isAuthenticated: Bool = false
///     var hasAnyToken: Bool = false
///     func makeSignInURL() -> URL? { nil }
///     func signOut() {}
///     func handleCallback(_ url: URL) {}
///     func makeSignInStream() -> AsyncStream<Bool> { AsyncStream { _ in } }
/// }
/// ```
@MainActor
public protocol OAuthServiceProtocol: AnyObject {
    /// `true` when a **non-empty** OAuth token is present in the token store (e.g. Keychain).
    /// Use this to determine whether the user has signed in via the native OAuth flow.
    ///
    /// - Note: The concrete implementation reads the token store (Keychain) directly on
    ///   every call — it intentionally bypasses any in-memory `TokenCache`. This is
    ///   correct because `isAuthenticated` drives UI state; a stale cache hit would show
    ///   the wrong sign-in indicator. The Keychain read is synchronous and cheap.
    ///
    /// - Note: **Behaviour change (PR #75).** Empty strings are rejected as invalid tokens.
    ///   Previously the contract was `tokenStore.load() != nil` — a stored empty string `""`
    ///   returned `true`. The contract is now `.map { !$0.isEmpty } ?? false` — empty strings
    ///   return `false`. This fixes the mismatch where `isAuthenticated == true` while
    ///   `token()` returns `nil` for a corrupted Keychain entry. Conformers and test mocks
    ///   that previously relied on `!= nil` semantics must be updated to match.
    ///   Test doubles should expose `isAuthenticated` as a plain `var Bool = false` — a fixed
    ///   stub that tests set directly, not a Keychain-reading computed property. The
    ///   empty-string rejection behaviour lives in `OAuthService` (the concrete conformer)
    ///   and is exercised by `OAuthServiceAuthStateTests` in `OAuthTokenKitTests`. If you
    ///   add a new conformer that reads from a real token store, its `isAuthenticated` must
    ///   implement `.map { !$0.isEmpty } ?? false` semantics, not the old `!= nil` contract.
    var isAuthenticated: Bool { get }

    /// `true` when any usable GitHub token is available — OAuth token, `GH_TOKEN`,
    /// or `GITHUB_TOKEN` environment variable.
    /// Use this to determine whether API calls can proceed at all.
    ///
    /// - Note: Delegates to `isAuthenticated` first, so a signed-in user pays only one
    ///   Keychain read. A second read only occurs when `isAuthenticated` returns `false`
    ///   and the env-var fallback is checked. The maximum cost is two Keychain reads
    ///   (not three — evaluating both properties back-to-back, e.g. in `SettingsView.init`,
    ///   costs one read if signed in, two if signed out via env var).
    var hasAnyToken: Bool { get }

    /// Builds and returns the GitHub OAuth authorization URL, storing the CSRF nonce.
    /// The caller is responsible for opening the URL (e.g. `NSWorkspace.shared.open(url)`).
    /// Returns `nil` if the URL cannot be constructed.
    func makeSignInURL() -> URL?

    /// Clears the stored token and emits a sign-out event to all stream consumers.
    func signOut()

    /// Handles the OAuth redirect URL from the OS, verifying the CSRF state nonce
    /// and exchanging the authorization code for an access token.
    func handleCallback(_ url: URL)

    /// Returns a new `AsyncStream<Bool>` that fires once per sign-in attempt.
    /// `true` = success, `false` = failure.
    func makeSignInStream() -> AsyncStream<Bool>
}
