// GitHubClient.swift
// GitHubClient

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
// Tests inject mocks via the secondary init:
//
//   let github = GitHubClient(
//       oauthService: MockOAuthService(),
//       transport: MockTransport()
//   )
//
// ## Why a facade?
//
// Without this type, `OAuthService`, `GitHubTransport`, and `TokenCache`
// are constructed independently with no shared token path:
//
// - `OAuthService` saves tokens to `KeychainTokenStore`.
// - `GitHubTransport` reads tokens via a separate closure.
// - `TokenCache` exists but is never wired into either.
//
// This facade is the single wiring point that closes all three gaps.

/// A facade that owns and wires `OAuthService`, `GitHubTransport`, and
/// `TokenCache` under a single initialiser.
///
/// Use the production init for app targets; use the test init to inject
/// protocol mocks without touching the Keychain or network.
///
/// ## Isolation note
/// `GitHubClient` is not annotated `@MainActor` at the type level, even
/// though `oauthService` stores `any OAuthServiceProtocol` whose protocol
/// is `@MainActor`-isolated. This is intentional for the current extraction
/// phase — the production init is `@MainActor` and `AppDelegate` (the only
/// call site) satisfies that. A type-level `@MainActor` annotation is
/// deferred to #1914 when the remaining `Keychain`/`RunBotCore` call sites
/// are also migrated, at which point the full isolation boundary can be
/// made compiler-enforced without stranding legacy callers.
public final class GitHubClient {

    /// The OAuth service — manages sign-in, sign-out, and token persistence.
    public let oauthService: any OAuthServiceProtocol

    /// The transport — handles all authenticated GitHub API requests.
    public let transport: any GitHubTransportProtocol

    // MARK: - Production init

    /// Creates a fully wired `GitHubClient` backed by the macOS Keychain.
    ///
    /// Internally constructs one `KeychainTokenStore`, one `TokenCache`, one
    /// `OAuthService`, and one `GitHubTransport` — all sharing the same token
    /// path. `TokenCache.invalidate()` is called automatically after every
    /// successful sign-in and sign-out.
    ///
    /// Must be called on the main actor because `OAuthService.init` is
    /// `@MainActor`-isolated. `AppDelegate` — the only production call site —
    /// satisfies this requirement automatically.
    ///
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - service: The keychain service name (e.g. your app's bundle identifier).
    ///   - account: The keychain account name (e.g. `"github-oauth-token"`).
    ///   - logger: Optional logger for diagnostic messages.
    @MainActor
    public init(
        clientID: String,
        clientSecret: String,
        service: String,
        account: String,
        logger: (any GitHubLogger)? = nil
    ) {
        let store = KeychainTokenStore(service: service, account: account, logger: logger)
        let cache = TokenCache(tokenStore: store, logger: logger)
        let oauth = OAuthService(
            clientID: clientID,
            clientSecret: clientSecret,
            tokenStore: store,
            logger: logger,
            onTokenSaved: { cache.invalidate() },
            onTokenDeleted: { cache.invalidate() }
        )
        let transport = GitHubTransport(
            tokenProvider: { cache.token() },
            logger: logger
        )
        self.oauthService = oauth
        self.transport = transport
    }

    // MARK: - Test init

    /// Creates a `GitHubClient` with injected protocol mocks.
    ///
    /// Use in tests to avoid Keychain or network access. Inject a
    /// `MockOAuthService` and `MockTransport` at whatever granularity
    /// the test requires.
    ///
    /// Intentionally nonisolated — it only assigns protocol existentials
    /// and never calls any `@MainActor`-isolated code directly.
    ///
    /// ⚠️ Callers must pass a `@MainActor`-isolated mock for `oauthService`
    /// to satisfy `OAuthServiceProtocol`'s `@MainActor` constraint. A mock
    /// that is not `@MainActor`-isolated will not compile.
    ///
    /// - Parameters:
    ///   - oauthService: A mock or stub conforming to `OAuthServiceProtocol`.
    ///   - transport: A mock or stub conforming to `GitHubTransportProtocol`.
    public init(
        oauthService: any OAuthServiceProtocol,
        transport: any GitHubTransportProtocol
    ) {
        self.oauthService = oauthService
        self.transport = transport
    }
}
