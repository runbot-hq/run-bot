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
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - service: The keychain service name. Defaults to `"run-bot"`.
    ///   - account: The keychain account name. Defaults to `"github-oauth-token"`.
    ///   - logger: Optional logger for diagnostic messages.
    public init(
        clientID: String,
        clientSecret: String,
        service: String = "run-bot",
        account: String = "github-oauth-token",
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
