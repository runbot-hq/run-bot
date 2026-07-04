// GitHubClientTests.swift
// GitHubClientTests
//
// Unit tests for `GitHubClient` — the facade that owns and wires
// OAuthService, GitHubTransport, and TokenCache.
//
// These tests use the test-init injection path exclusively; no Keychain
// or network access occurs.

import Foundation
import Testing
@testable import GitHubClient

// MARK: - GitHubClientTests

@Suite("GitHubClient")
struct GitHubClientTests {

    // MARK: - Helpers

    /// Builds a `GitHubClient` with injected mocks.
    @MainActor
    private func makeSUT() -> (client: GitHubClient, oauth: MockOAuthService, transport: MockTransport) {
        let oauth = MockOAuthService()
        let transport = MockTransport()
        let client = GitHubClient(oauthService: oauth, transport: transport)
        return (client, oauth, transport)
    }

    // MARK: - Test-init injection

    /// The test init exposes the injected oauth service at `client.oauthService`.
    @Test @MainActor
    func testInit_oauthService_isInjectedMock() async {
        let (client, oauth, _) = makeSUT()
        // OAuthServiceProtocol is AnyObject-constrained; use ObjectIdentifier for identity.
        #expect(ObjectIdentifier(client.oauthService as AnyObject) == ObjectIdentifier(oauth))
    }

    /// The test init exposes the injected transport at `client.transport`.
    @Test @MainActor
    func testInit_transport_isInjectedMock() async {
        let (client, _, transport) = makeSUT()
        // GitHubTransportProtocol is Sendable (not AnyObject); cast via AnyObject for identity.
        #expect(ObjectIdentifier(client.transport as AnyObject) == ObjectIdentifier(transport))
    }

    // MARK: - oauthService forwarding

    /// `isAuthenticated` reflects the mock's value.
    @Test @MainActor
    func oauthService_isAuthenticated_reflectsMockValue() async {
        let (client, oauth, _) = makeSUT()
        oauth.isAuthenticated = true
        #expect(client.oauthService.isAuthenticated == true)
    }

    /// `hasAnyToken` reflects the mock's value.
    @Test @MainActor
    func oauthService_hasAnyToken_reflectsMockValue() async {
        let (client, oauth, _) = makeSUT()
        oauth.hasAnyToken = true
        #expect(client.oauthService.hasAnyToken == true)
    }

    /// `handleCallback(_:)` is forwarded to the mock and recorded.
    @Test @MainActor
    func oauthService_handleCallback_isRecorded() async {
        let (client, oauth, _) = makeSUT()
        let url = URL(string: "runbot://oauth/callback?code=abc&state=xyz")!
        client.oauthService.handleCallback(url)
        #expect(oauth.handleCallbackURLs == [url])
    }

    /// `signOut()` is forwarded to the mock and increments the call count.
    @Test @MainActor
    func oauthService_signOut_incrementsCallCount() async {
        let (client, oauth, _) = makeSUT()
        client.oauthService.signOut()
        #expect(oauth.signOutCallCount == 1)
    }

    // MARK: - transport forwarding

    /// `cancelRun` is forwarded to the mock and recorded.
    @Test @MainActor
    func transport_cancelRun_isRecorded() async {
        let (client, _, transport) = makeSUT()
        transport.onCancelRun = { _, _ in true }
        let result = await client.transport.cancelRun(runID: 42, scope: "owner/repo")
        #expect(result == true)
        #expect(transport.cancelRunCalls.count == 1)
        #expect(transport.cancelRunCalls[0].runID == 42)
        #expect(transport.cancelRunCalls[0].scope == "owner/repo")
    }

    /// `apiAsync` is forwarded and the endpoint is recorded by the spy.
    @Test @MainActor
    func transport_apiAsync_isRecorded() async {
        let (client, _, transport) = makeSUT()
        let expected = "{\"key\":\"value\"}".data(using: .utf8)!
        transport.onApiAsync = { _, _ in expected }
        let data = await client.transport.apiAsync("/repos/owner/repo")
        #expect(data == expected)
        #expect(transport.apiAsyncEndpoints == ["/repos/owner/repo"])
    }

    // MARK: - MockTransport defaults

    /// Default `cancelRun` returns `false` without explicit wiring.
    @Test @MainActor
    func mockTransport_cancelRun_defaultReturnsFalse() async {
        let transport = MockTransport()
        let result = await transport.cancelRun(runID: 1, scope: "owner/repo")
        #expect(result == false)
    }

    /// Default `apiAsync` returns `nil` without explicit wiring.
    @Test @MainActor
    func mockTransport_apiAsync_defaultReturnsNil() async {
        let transport = MockTransport()
        let data = await transport.apiAsync("/any")
        #expect(data == nil)
    }

    // MARK: - MockOAuthService defaults

    /// Default `isAuthenticated` is `false`.
    @Test @MainActor
    func mockOAuth_isAuthenticated_defaultFalse() {
        let oauth = MockOAuthService()
        #expect(oauth.isAuthenticated == false)
    }

    /// `makeSignInURL()` returns `nil` by default and increments the call count.
    @Test @MainActor
    func mockOAuth_makeSignInURL_defaultNil() {
        let oauth = MockOAuthService()
        let url = oauth.makeSignInURL()
        #expect(url == nil)
        #expect(oauth.makeSignInURLCallCount == 1)
    }

    /// `makeSignInURL()` returns the configured URL when `signInURLToReturn` is set.
    @Test @MainActor
    func mockOAuth_makeSignInURL_returnsConfiguredURL() {
        let oauth = MockOAuthService()
        oauth.signInURLToReturn = URL(string: "https://github.com/login/oauth/authorize?client_id=test")
        let url = oauth.makeSignInURL()
        #expect(url == oauth.signInURLToReturn)
    }

    /// `signOut()` increments `signOutCallCount` on each call.
    @Test @MainActor
    func mockOAuth_signOut_countAccumulates() {
        let oauth = MockOAuthService()
        oauth.signOut()
        oauth.signOut()
        #expect(oauth.signOutCallCount == 2)
    }

    /// `triggerSignIn(true)` delivers a `true` event to an active stream consumer.
    @Test @MainActor
    func mockOAuth_triggerSignIn_deliversToStream() async {
        let oauth = MockOAuthService()
        let stream = oauth.makeSignInStream()
        oauth.triggerSignIn(true)
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        #expect(value == true)
    }

    /// `triggerSignOut()` delivers an event to an active stream consumer.
    @Test @MainActor
    func mockOAuth_triggerSignOut_deliversToStream() async {
        let oauth = MockOAuthService()
        let stream = oauth.makeSignOutStream()
        oauth.triggerSignOut()
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        #expect(value == ())
    }
}
