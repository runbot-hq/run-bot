// OAuthService.swift
// GitHubClient
import Foundation

/// Manages OAuth state and behaviour. No AppKit dependency.
@MainActor
public final class OAuthService: OAuthServiceProtocol {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let redirectURI = GitHubConstants.oauthRedirectURI
    private let scopes = "repo read:org admin:org manage_runners:org workflow"
    private let authorizeURL = "\(GitHubConstants.base)/login/oauth/authorize"
    private let accessTokenURL = "\(GitHubConstants.base)/login/oauth/access_token"
    private var pendingState: String?

    private let clientID: String
    private let clientSecret: String
    private let tokenStore: any TokenStore
    private let logger: (any GitHubLogger)?

    /// Creates a new `OAuthService`.
    /// - Parameters:
    ///   - clientID: The GitHub OAuth app client ID.
    ///   - clientSecret: The GitHub OAuth app client secret.
    ///   - tokenStore: The backing store used to save/delete the OAuth token.
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

    // MARK: - Sign-out multicast

    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

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

    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

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

    private func fireSignIn(_ success: Bool) {
        logger?.log("OAuthService › fireSignIn — success=\(success), consumers=\(signInContinuations.count)", category: "transport")
        signInContinuations.values.forEach { $0.yield(success) }
    }

    // MARK: - Sign In

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

    public func handleCallback(_ url: URL) {
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

    private func fetchTokenData(request: URLRequest) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

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

// MARK: - Private models

private struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token" // skipcq: SCT-A000
        case error
        case errorDescription = "error_description"
    }
    var debugKeys: [String] {
        var keys: [String] = []
        if accessToken != nil { keys.append("access_token") } // skipcq: SCT-A000
        if error != nil { keys.append("error") }
        if errorDescription != nil { keys.append("error_description") }
        return keys
    }
}

private struct OAuthTokenRequest: Encodable {
    let clientID: String
    let clientSecret: String
    let code: String
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id" // skipcq: SCT-A000
        case clientSecret = "client_secret" // skipcq: SCT-A000
        case code
    }
}
