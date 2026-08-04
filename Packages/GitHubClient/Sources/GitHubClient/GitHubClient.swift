// GitHubClient.swift
// GitHubClient
internal import EnvTokenKit  // internal: no EnvTokenKit type appears in GitHubClient's public API
// Note: EnvTokenProviding (also from EnvTokenKit) does surface in TokenCache's
// public initialisers — but that requirement is handled by TokenCache.swift's own
// public import EnvTokenKit. Swift's import access is per-file; each file
// independently satisfies its own compiler requirement. The internal import here
// is correct and sufficient for this file specifically.
import Foundation
// public import OAuthTokenKit: two independent compiler requirements force this above internal:
// 1. `public let oauthService: any OAuthServiceProtocol` — OAuthServiceProtocol is an OAuthTokenKit
//    type in a public property declaration; Swift forbids naming it via an internally-imported module.
// 2. TokenCache's public initialisers name `TokenStore` (an OAuthTokenKit protocol) directly in
//    their public parameter lists; re-exposing TokenCache through the test init's `tokenCache:`
//    parameter inherits the same constraint.
// Do NOT downgrade to internal without resolving both of the above.
// See also: TokenCache.swift — also requires public import OAuthTokenKit and public import
// EnvTokenKit for its own independent compiler reasons (public initialisers with protocol-typed
// parameters). Both imports are load-bearing in both files; removing the import here does not
// satisfy or remove the requirement in TokenCache.swift, and vice versa.
public import OAuthTokenKit

// MARK: - GitHubClient
//
// Top-level facade that owns and wires all GitHubClient components.
//
// Production consumers create a single instance and hold it for the
// app lifetime:
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       logger: MyLogger()
//   )
//
// Custom scopes (optional — defaults to GitHubScopes.default):
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       scopes: GitHubScopes.default + [GitHubScopes.readUser]
//   )
//
// Custom redirect URI (optional — defaults to OAuthService.defaultRedirectURI):
//
//   let github = GitHubClient(
//       clientID: "your-client-id",
//       clientSecret: "your-client-secret",
//       service: "com.example.myapp",
//       account: "github-oauth-token",
//       redirectURI: "myapp-staging://oauth/callback"
//   )
//
// Tests inject mocks via the secondary init:
//
//   let github = GitHubClient(
//       oauthService: MockOAuthService(),
//       transport: MockTransport()
//   )

/// A facade that owns and wires `OAuthService`, `GitHubTransport`, and
/// `TokenCache` under a single initialiser.
///
/// Use the production init for app targets; use the test init to inject
/// protocol mocks without touching the Keychain or network.
///
/// ## Isolation
/// `GitHubClient` is `@MainActor`-isolated at the type level because
/// `oauthService` stores `any OAuthServiceProtocol` whose protocol is
/// `@MainActor`-isolated.
@MainActor
public final class GitHubClient {

    /// The OAuth service — manages sign-in, sign-out, and token persistence.
    public let oauthService: any OAuthServiceProtocol

    /// The transport — handles all authenticated GitHub API requests.
    public let transport: any GitHubTransportProtocol

    /// The in-memory token cache shared between `oauthService` and `transport`.
    ///
    /// Kept private to prevent callers from invoking `invalidate()` or `token()`
    /// directly — both operations are managed internally via the
    /// `onTokenSaved` / `onTokenDeleted` callbacks wired in `init`.
    /// Use `cachedToken` for read-only UI status checks.
    private let _tokenCache: TokenCache

    /// The env-token provider, stored separately so `discoverEnvironmentState()`
    /// can run an env-only resolution without going through the full token-cache
    /// chain (which also checks the Keychain and would return OAuth tokens).
    ///
    /// Typed to the protocol so no `EnvTokenKit` type leaks into the public API.
    private let _envProvider: any EnvTokenProviding

    /// Returns the currently selected authentication source.
    ///
    /// Closure-injected so `GitHubClient` (a package type) can read
    /// `GitHubAuthentication.selectedSource` (an app-layer type) without
    /// taking a dependency on the app module. The closure is evaluated on
    /// every `token()` call — no caching.
    ///
    /// Defaults to `{ .unauthenticated }` in the test init so tests that do
    /// not exercise source-switching get the zero-op behaviour (token() returns nil).
    private let _authSource: @Sendable @MainActor () -> GitHubAuthSource

    /// The token that the in-memory cache has already resolved, or `nil` if no
    /// `token()` call has completed yet during this process lifetime.
    ///
    /// This is a **synchronous, zero-I/O** read — it never spawns a login shell,
    /// reads the Keychain, or checks environment variables. It reflects only what
    /// a prior `token()` call has already resolved.
    ///
    /// ## Typical use
    /// UI code that needs to show an auth-status indicator without going `async`
    /// can read this property after at least one `token()` call has completed
    /// (e.g. from a `.task` modifier that awaits `token()` on appear).
    public var cachedToken: String? { _tokenCache.cachedToken }

    /// Resolves and returns the current token, dispatching to the correct
    /// credential source based on `selectedSource`.
    ///
    /// - `.oauth`           — resolves from the Keychain via `TokenCache`.
    /// - `.environment`     — resolves env-var / login-shell only; Keychain is skipped.
    /// - `.unauthenticated` — returns `nil` immediately; no I/O.
    ///
    /// This is the same path used by every authenticated API call. Call it from
    /// a `.task` modifier or other async context to warm the cache and then read
    /// `cachedToken` synchronously for UI status checks.
    public func token() async -> String? {
        switch _authSource() {
        case .oauth:
            return await _tokenCache.token()
        case .environment:
            // Env-only path: bypass the Keychain step in TokenCache so an OAuth
            // credential that happens to be present cannot silently satisfy the
            // request when the user has explicitly chosen environment auth.
            return await _envProvider.token()
        case .unauthenticated:
            return nil
        }
    }

    /// Probes `GH_TOKEN` / `GITHUB_TOKEN` via the env-only resolution path and
    /// returns the corresponding `EnvironmentTokenState`.
    ///
    /// Unlike `token()`, this method does **not** check the Keychain. It resolves
    /// only via the `EnvTokenProvider` (process env → login-shell fallback), so
    /// the result reflects purely whether an environment variable token is present,
    /// regardless of OAuth sign-in state.
    ///
    /// Use this from `AppState.start()` and `SettingsView.task` to seed
    /// `GitHubAuthentication.environmentState` without OAuth state leaking in.
    ///
    /// ## Caching
    /// The underlying `EnvTokenProvider` caches shell results — repeated calls are
    /// cheap once the shell path has resolved. See `EnvTokenProviding.token()` for
    /// the full caching contract.
    ///
    /// ## Variable detection
    /// Returns `.available(variable: .ghToken)` as a conservative label.
    /// Distinguishing `GH_TOKEN` vs `GITHUB_TOKEN` requires a separate env-var
    /// probe and is deferred to a Phase 2 enhancement (see #2459 §4.7).
    public func discoverEnvironmentState() async -> EnvironmentTokenState {
        let envToken = await _envProvider.token()
        if envToken != nil {
            return .available(variable: .ghToken)
        } else {
            return .unavailable
        }
    }

    // MARK: - Production init

    /// Creates a fully wired `GitHubClient` backed by the macOS Keychain.
    ///
    /// Internally constructs one `KeychainTokenStore`, one `EnvTokenProvider`,
    /// one `TokenCache`, one `OAuthService`, and one `GitHubTransport` — all
    /// sharing the same token path. `TokenCache.invalidate()` is called
    /// automatically after every successful sign-in and sign-out, which resets
    /// both the in-memory token cache and `EnvTokenProvider`'s shell outcome latch.
    ///
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - service: The keychain service name (e.g. your app's bundle identifier).
    ///   - account: The keychain account name (e.g. `"github-oauth-token"`).
    ///   - scopes: The OAuth scopes to request during sign-in. Defaults to
    ///     `GitHubScopes.default`. Must not be empty. Use `GitHubScopes`
    ///     constants for type safety and discoverability.
    ///   - redirectURI: The OAuth redirect URI sent to GitHub during authorisation.
    ///     Defaults to `OAuthService.defaultRedirectURI` (`runbot://oauth/callback`).
    ///     Override for staging environments, white-label builds, or a second OAuth app.
    ///     Existing call sites are unaffected — omitting this parameter preserves current behaviour.
    ///   - authSource: Closure that returns the currently selected authentication
    ///     source. Evaluated on every `token()` call. Pass
    ///     `{ appState.authentication.selectedSource }` at the construction site.
    ///     Defaults to `{ .unauthenticated }` — callers that do not need
    ///     source-switching can omit this parameter.
    ///   - logger: Optional logger for diagnostic messages.
    @MainActor
    public init(
        clientID: String,
        clientSecret: String,
        service: String,
        account: String,
        scopes: [String] = GitHubScopes.default,
        redirectURI: String = OAuthService.defaultRedirectURI,
        authSource: @escaping @Sendable @MainActor () -> GitHubAuthSource = { .unauthenticated },
        logger: (any GitHubLogger)? = nil
    ) {
        // Bridge GitHubLogger → log closure for kit injection.
        // GitHubLogger stays in GitHubClient/Transport — kits are closure-injected
        // to avoid any shared logger dependency between targets.
        //
        // ## Why `if let` and not `.map { l in { ... } }`
        // The spec (#73/#74) shows a single-expression map form as an example.
        // Here the capture body requires a `@Sendable` attribute on the closure
        // literal, which cannot be expressed inside a `.map` trailing closure
        // without a cast. The `if let` + explicit `@Sendable` annotation is the
        // idiomatic form for a multi-attribute closure at an imperative call site.
        // Both forms produce identical code; this is not a deviation from the
        // spec's intent — only from its illustrative example.
        let log: (@Sendable (String, String) -> Void)?
        if let lg = logger {
            log = { @Sendable message, category in lg.log(message, category: category) }
        } else {
            log = nil
        }
        // public import OAuthTokenKit — not internal — for two reasons, both compiler-enforced:
        // 1. TokenCache's public initialisers name TokenStore (an OAuthTokenKit protocol) directly
        //    in their public parameter lists. TokenCache itself is constructed here and re-exposed
        //    through the test-only init's `tokenCache:` parameter. Swift forbids a public
        //    declaration from using an internally-imported type.
        // 2. `public let oauthService: any OAuthServiceProtocol` on GitHubClient names
        //    OAuthServiceProtocol (an OAuthTokenKit protocol) in a public property declaration.
        //    This independently requires public import even if reason 1 were resolved.
        // KeychainTokenStore and OAuthService are concrete OAuthTokenKit types that never appear
        // in GitHubClient's own public API surface. The public import is forced by TokenCache's
        // signature and the oauthService property, not by the concrete wiring done here.
        let store = KeychainTokenStore(service: service, account: account, log: log)
        // internal import EnvTokenKit — unlike OAuthTokenKit above, this stays internal because
        // no public API of GitHubClient names any EnvTokenKit type. EnvTokenProvider is
        // constructed locally and immediately erased to `any EnvTokenProviding` before being
        // passed into TokenCache, which only ever knows the protocol — see TokenCache Boundary
        // Rule in #74. EnvTokenProvider is the only EnvTokenKit concrete type named in this file.
        let envProvider = EnvTokenProvider(log: log)
        self._envProvider = envProvider
        let cache = TokenCache(tokenStore: store, envProvider: envProvider, logger: logger)
        let oauth = OAuthService(
            clientID: clientID,
            clientSecret: clientSecret,
            tokenStore: store,
            scopes: scopes,
            redirectURI: redirectURI,
            log: log,
            session: URLSession.shared,
            // Both callbacks call invalidate() so the next token() call re-resolves
            // from the store after any credential change. invalidate() resets both
            // the in-memory token cache AND EnvTokenProvider's shell outcome latch —
            // see EnvTokenProvider.invalidate() for the full .failed vs .notFound
            // reset policy. Side-effect: a user whose shell is broken (.failed latch)
            // will re-spawn /bin/zsh on the next token() call after *both* sign-in
            // and sign-out — not just sign-out. Low-frequency and intentional; tracked in #68.
            onTokenSaved: { cache.invalidate() },
            onTokenDeleted: { cache.invalidate() }
        )
        // Dedicated URLSession with no disk cache for the GitHub API transport.
        // URLSession.shared uses a disk-backed URLCache by default. GitHub's /logs
        // endpoints 302-redirect to short-lived S3 pre-signed URLs; without urlCache = nil,
        // URLSession can replay a cached 302 pointing at an expired S3 URL ~20 minutes
        // later, causing every step log fetch to silently fail after the first read.
        // req.cachePolicy = .reloadIgnoringLocalCacheData on the request (makeRawRequest)
        // is insufficient alone — the session-level URLCache can still serve cached
        // redirect responses regardless of the per-request policy.
        // OAuthService above intentionally keeps URLSession.shared — its OAuth endpoints
        // do not redirect to S3 and benefit from connection reuse via the shared session.
        let apiSession: URLSession = {
            let config = URLSessionConfiguration.default
            config.urlCache = nil
            return URLSession(configuration: config)
        }()
        let transport = GitHubTransport(
            session: apiSession,
            tokenProvider: { await cache.token() },
            logger: logger
        )
        // NOT a dead assignment — read by free-function shims in GitHubTransportShims.swift.
        // If sharedTransportStorage is renamed or moved, update the reference there too or
        // Periphery will flag this as unused again. The cross-file dependency is intentional;
        // a module-level stored var is the correct seam for the shim pattern used here.
        sharedTransportStorage = transport
        self.oauthService = oauth
        self.transport = transport
        self._tokenCache = cache
        self._authSource = authSource
    }

    // MARK: - Test init

    /// Creates a `GitHubClient` with injected protocol mocks.
    ///
    /// Accepts `any OAuthServiceProtocol` and `any GitHubTransportProtocol`
    /// directly, so the caller controls all behaviour at mock-construction time.
    ///
    /// WHY NO `scopes:` PARAMETER:
    /// The production init accepts `scopes:` to pass them through to
    /// `OAuthService`. The test init bypasses `OAuthService` entirely — the
    /// caller passes a fully-constructed mock, which already encodes whatever
    /// scope behaviour the test requires. Adding `scopes:` here would be
    /// misleading: there is no `OAuthService` to forward them to, and a test
    /// author who adds scopes expecting OAuth behaviour would get a silent no-op.
    ///
    /// ## `tokenCache` and `invalidate()` in tests
    /// The test init does **not** wire `onTokenSaved` / `onTokenDeleted` callbacks
    /// — there is no `OAuthService` to fire them. Tests that exercise sign-out or
    /// credential rotation and need `cachedToken` to reflect the new state must
    /// call `tokenCache.invalidate()` manually, or pass a pre-populated
    /// `TokenCache` instance via the `tokenCache` parameter.
    ///
    /// - Note: Does **not** accept a `scopes:` or `redirectURI:` parameter —
    ///   it takes `any OAuthServiceProtocol` directly, which already encapsulates
    ///   both scope and redirect URI configuration. No changes needed here.
    ///
    /// - Parameters:
    ///   - oauthService: A mock or stub conforming to `OAuthServiceProtocol`.
    ///   - transport: A mock or stub conforming to `GitHubTransportProtocol`.
    ///   - tokenCache: An optional pre-configured `TokenCache`. When `nil` a
    ///     `NullTokenStore`-backed cache is constructed automatically — suitable
    ///     for tests that do not exercise the token-resolution path.
    public init(
        oauthService: any OAuthServiceProtocol,
        transport: any GitHubTransportProtocol,
        tokenCache: TokenCache? = nil,
        authSource: @escaping @Sendable @MainActor () -> GitHubAuthSource = { .unauthenticated }
    ) {
        self.oauthService = oauthService
        self.transport = transport
        self._tokenCache = tokenCache ?? TokenCache(tokenStore: NullTokenStore())
        // Test init always uses NullEnvTokenProvider — discoverEnvironmentState()
        // returns .unavailable. Tests that need a custom env-discovery result
        // should stub at the GitHubAuthentication level, not at the provider level.
        self._envProvider = NullEnvTokenProvider()
        self._authSource = authSource
    }
}
