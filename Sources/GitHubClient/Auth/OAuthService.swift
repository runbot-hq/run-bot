// OAuthService.swift
// GitHubClient
import Foundation

// MARK: - OAuthService
//
// Implements the GitHub OAuth Authorization Code flow.
//
// @MainActor ensures all access to `pendingState` and continuation registries
// is serialised on the main thread. This matches how AppKit delivers
// application(_:open:) callbacks and how SwiftUI reads `isSignedIn`.
//
// Flow:
// 1. makeSignInURL() generates a random state nonce, stores it, and returns
//    the GitHub authorization URL. The caller is responsible for opening it
//    (e.g. NSWorkspace.shared.open(url) in SettingsView / AppDelegate).
// 2. The user clicks "Authorize" on GitHub's consent screen.
// 3. GitHub redirects to runbot://oauth/callback?code=...&state=...
// 4. AppDelegate.application(_:open:) catches the URL and calls handleCallback(_:).
// 5. handleCallback verifies the state param matches pendingState (CSRF guard),
//    then exchanges the code for an access token via POST to GitHub.
// 6. Token is saved to tokenStore. fireSignIn(_:) yields the result to all
//    registered makeSignInStream() consumers.

/// Manages OAuth state and behaviour. No AppKit dependency.
@MainActor
public final class OAuthService: OAuthServiceProtocol {
    /// Shared `JSONDecoder` — reused across token-exchange decode calls.
    private let decoder = JSONDecoder()
    /// Shared `JSONEncoder` — reused across token-exchange encode calls.
    private let encoder = JSONEncoder()
    /// The OAuth redirect URI. Must match the value registered in the GitHub OAuth app settings.
    private let redirectURI = GitHubConstants.oauthRedirectURI
    /// OAuth scopes requested during sign-in.
    private let scopes = "repo read:org admin:org manage_runners:org workflow"
    /// GitHub OAuth authorisation URL.
    private let authorizeURL = "\(GitHubConstants.base)/login/oauth/authorize"
    /// GitHub OAuth token-exchange URL.
    private let accessTokenURL = "\(GitHubConstants.base)/login/oauth/access_token"
    /// CSRF nonce generated in makeSignInURL(), verified in handleCallback(). Cleared after use.
    private var pendingState: String?

    /// The GitHub OAuth app client ID.
    private let clientID: String
    /// The GitHub OAuth app client secret.
    private let clientSecret: String
    /// The backing store used to save/delete/load the OAuth token.
    private let tokenStore: any TokenStore
    /// Optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?

    /// Creates a new `OAuthService`.
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - tokenStore: The backing store used to save/delete/load the OAuth token.
    ///   - logger: Optional logger for diagnostic messages.
    public init(
        clientID: String,
        clientSecret: String,
        tokenStore: any TokenStore,
        logger: (any GitHubLogger)? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenStore = tokenStore
        self.logger = logger
    }

    // MARK: - OAuthServiceProtocol — Auth state

    /// `true` when a valid OAuth token is present in the token store (e.g. Keychain).
    public var isAuthenticated: Bool {
        tokenStore.load() != nil
    }

    /// `true` when any usable GitHub token is available — OAuth token,
    /// `GH_TOKEN`, or `GITHUB_TOKEN` environment variable.
    ///
    /// Mirrors the resolution priority of `TokenCache.token()` without
    /// requiring a `TokenCache` reference here.
    public var hasAnyToken: Bool {
        if tokenStore.load() != nil { return true }
        let env = ProcessInfo.processInfo.environment
        return env["GH_TOKEN"] != nil || env["GITHUB_TOKEN"] != nil
    }

    // MARK: - Sign-out multicast

    /// Registered sign-out continuations keyed by UUID — one per active consumer.
    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Returns a new `AsyncStream<Void>` that fires once per `signOut()` call.
    public func makeSignOutStream() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Void>.makeStream()
        signOutContinuations[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signOutContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    // MARK: - Sign-in multicast

    /// Registered sign-in continuations keyed by UUID — one per active consumer.
    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Returns a new `AsyncStream<Bool>` that fires once per sign-in attempt (`true` = success).
    public func makeSignInStream() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        signInContinuations[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signInContinuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// Yields `success` to every registered sign-in continuation.
    private func fireSignIn(_ success: Bool) {
        logger?.log("OAuthService › fireSignIn — success=\(success), consumers=\(signInContinuations.count)", category: "transport")
        signInContinuations.values.forEach { $0.yield(success) }
    }

    // MARK: - Sign In

    /// Builds a GitHub OAuth authorize URL with a CSRF state nonce.
    public func makeSignInURL() -> URL? {
        logger?.log("OAuthService › makeSignInURL — building OAuth URL", category: "transport")
        let state = UUID().uuidString
        pendingState = state
        guard var comps = URLComponents(string: authorizeURL) else {
            logger?.log("OAuthService › makeSignInURL: malformed authorizeURL — aborting", category: "transport")
            pendingState = nil
            return nil
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = comps.url else {
            logger?.log("OAuthService › makeSignInURL: failed to build URL — aborting", category: "transport")
            pendingState = nil
            return nil
        }
        logger?.log("OAuthService › makeSignInURL — URL built, returning to caller", category: "transport")
        return url
    }

    // MARK: - Sign Out

    /// Clears the pending state, deletes the token, and emits a sign-out event.
    public func signOut() {
        logger?.log("OAuthService › signOut — called, pendingState=\(pendingState != nil ? "set" : "nil")", category: "transport")
        pendingState = nil
        let deleted = tokenStore.delete()
        logger?.log("OAuthService › signOut — tokenStore.delete result=\(deleted)", category: "transport")
        if deleted {
            logger?.log("OAuthService › signOut — emitting didSignOut to \(signOutContinuations.count) consumer(s)", category: "transport")
            signOutContinuations.values.forEach { $0.yield(()) }
        } else {
            logger?.log("OAuthService › signOut: tokenStore.delete failed — sign-out suppressed", category: "transport")
        }
    }

    // MARK: - Callback Handler

    /// Processes the OAuth redirect URL from GitHub.
    ///
    /// Extracts the `code` and `state` query parameters, validates the CSRF
    /// state nonce, then kicks off the token-exchange flow.
    public func handleCallback(_ url: URL) {
        // Log scheme+host only — the full URL contains the one-time `code` query
        // parameter which is sensitive for a short window. Never log url.absoluteString
        // or url.query here; doing so would leak the live credential into unified logs.
        let safeURL = "\(url.scheme ?? "")://\(url.host ?? "")"
        logger?.log("OAuthService › handleCallback — url=\(safeURL)", category: "transport")
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            logger?.log("OAuthService › handleCallback — missing code param, calling fireSignIn(false)", category: "transport")
            fireSignIn(false)
            return
        }
        guard let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value else {
            logger?.log("OAuthService › handleCallback: no state param in redirect URL", category: "transport")
            pendingState = nil
            fireSignIn(false)
            return
        }
        guard returnedState == pendingState else {
            logger?.log("OAuthService › handleCallback: state mismatch — possible CSRF attempt, rejecting", category: "transport")
            pendingState = nil
            fireSignIn(false)
            return
        }
        logger?.log("OAuthService › handleCallback — state OK, exchanging code", category: "transport")
        pendingState = nil
        Task { await exchangeCode(code) }
    }

    // MARK: - Token Exchange

    /// Exchanges the one-time authorization code for an access token.
    ///
    /// 1. Builds and sends the token-exchange request.
    /// 2. Decodes the response.
    /// 3. Validates the response and extracts the token.
    /// 4. Saves the token via `tokenStore`.
    /// 5. Notifies sign-in consumers of the result.
    private func exchangeCode(_ code: String) async {
        logger?.log("OAuthService › exchangeCode — POST to GitHub", category: "transport")
        let req: URLRequest
        do {
            req = try makeTokenRequest(code: code)
        } catch {
            logger?.log("OAuthService › exchangeCode: failed to encode request body — aborting", category: "transport")
            fireSignIn(false)
            return
        }
        let data: Data
        do {
            data = try await fetchTokenData(request: req)
        } catch {
            logger?.log("OAuthService › exchangeCode: network error — \(error.localizedDescription), calling fireSignIn(false)", category: "transport")
            fireSignIn(false)
            return
        }
        let response: OAuthTokenResponse
        do {
            response = try decoder.decode(OAuthTokenResponse.self, from: data)
        } catch {
            logger?.log("OAuthService › exchangeCode: decode error — \(error.localizedDescription), calling fireSignIn(false)", category: "transport")
            fireSignIn(false)
            return
        }
        guard let token = handleTokenResponse(response) else {
            fireSignIn(false)
            return
        }
        logger?.log("OAuthService › exchangeCode — got access_token (len=\(token.count)), saving to store", category: "transport")
        let saved = tokenStore.save(token)
        logger?.log("OAuthService › exchangeCode — tokenStore.save result=\(saved), calling fireSignIn(\(saved))", category: "transport")
        if !saved { logger?.log("OAuthService › exchangeCode: tokenStore.save failed", category: "transport") }
        fireSignIn(saved)
    }

    /// Builds the token-exchange `URLRequest`.
    private func makeTokenRequest(code: String) throws -> URLRequest {
        guard let url = URL(string: accessTokenURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OAuthTokenRequest(clientID: clientID, clientSecret: clientSecret, code: code)
        req.httpBody = try encoder.encode(body)
        return req
    }

    /// Performs the network call for the token exchange.
    ///
    /// - Parameter request: The pre-built `URLRequest` to send.
    /// - Returns: The raw response `Data`.
    /// - Throws: Any `URLError` from the underlying `URLSession`.
    private func fetchTokenData(request: URLRequest) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// Validates the GitHub-level token response and extracts the access token.
    ///
    /// Logs and returns `nil` for both GitHub-reported errors and missing/empty tokens.
    ///
    /// - Parameter response: The decoded `OAuthTokenResponse`.
    /// - Returns: The access token string on success; `nil` on failure.
    private func handleTokenResponse(_ response: OAuthTokenResponse) -> String? {
        if let errorCode = response.error {
            let desc = response.errorDescription ?? ""
            logger?.log("OAuthService › exchangeCode: GitHub error=\(errorCode) \(desc)", category: "transport")
            return nil
        }
        guard let token = response.accessToken, !token.isEmpty else {
            logger?.log("OAuthService › exchangeCode: no access_token in response — keys=\(response.debugKeys)", category: "transport")
            return nil
        }
        return token
    }
}

// MARK: - OAuthTokenResponse

/// Response body from the GitHub OAuth token exchange.
/// GitHub returns HTTP 200 even on failure, so both `accessToken` and `error` are optional.
private struct OAuthTokenResponse: Decodable {
    /// The access token returned on success; `nil` when GitHub reports an error.
    let accessToken: String?
    /// Short error code returned by GitHub on failure (e.g. `"bad_verification_code"`).
    let error: String?
    /// Human-readable description of the error, if present.
    let errorDescription: String?

    /// Maps Swift property names to the snake_case JSON keys returned by the GitHub OAuth endpoint.
    private enum CodingKeys: String, CodingKey {
        /// JSON key: `access_token`.
        case accessToken = "access_token" // skipcq: SCT-A000
        /// JSON key: `error`.
        case error
        /// JSON key: `error_description`.
        case errorDescription = "error_description"
    }

    /// Returns the names of modelled fields that are non-nil, for safe diagnostic logging.
    var debugKeys: [String] {
        var keys: [String] = []
        if accessToken != nil { keys.append("access_token") } // skipcq: SCT-A000
        if error != nil { keys.append("error") }
        if errorDescription != nil { keys.append("error_description") }
        return keys
    }
}

// MARK: - OAuthTokenRequest

// periphery:ignore
/// OAuth token-exchange request body for the GitHub API.
private struct OAuthTokenRequest: Encodable {
    /// The GitHub OAuth app client ID.
    let clientID: String
    /// The GitHub OAuth app client secret.
    let clientSecret: String
    /// The one-time authorization code received in the OAuth redirect callback.
    let code: String

    /// Maps Swift property names to the snake_case JSON keys expected by the GitHub OAuth endpoint.
    private enum CodingKeys: String, CodingKey {
        /// JSON key: `client_id`.
        case clientID = "client_id" // skipcq: SCT-A000
        /// JSON key: `client_secret`.
        case clientSecret = "client_secret" // skipcq: SCT-A000
        /// JSON key: `code`.
        case code
    }
}
