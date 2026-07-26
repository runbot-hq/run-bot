// GitHubClientTests.swift
// GitHubClientTests
//
// Unit tests for `GitHubClient` — the facade that owns and wires
// OAuthService, GitHubTransport, and TokenCache.
//
// Architecture note: `GitHubClient` is a pure DI facade with no logic
// of its own beyond property storage and wiring. These tests verify:
//   1. Injection wiring (properties point to the injected mocks)
//   2. Behavioural forwarding (calls on client reach the mock and record correctly)
//
// Mock correctness tests (testing the mock itself) are intentionally
// excluded — they belong in MockSanityTests if ever needed.
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

    // MARK: - makeSignInURL forwarding (behavioural)

    /// `makeSignInURL()` called via the client reaches the OAuth service and
    /// increments its call count — verifying the call is truly forwarded.
    @Test @MainActor
    func client_makeSignInURL_isForwardedToOAuthService() {
        let (client, oauth, _) = makeSUT()
        _ = client.oauthService.makeSignInURL()
        #expect(oauth.makeSignInURLCallCount == 1)
    }

    /// When `signInURLToReturn` is configured on the mock, `makeSignInURL()`
    /// called through the client returns that exact URL.
    @Test @MainActor
    func client_makeSignInURL_returnsConfiguredURL() {
        let (client, oauth, _) = makeSUT()
        let expected = URL(string: "https://github.com/login/oauth/authorize?client_id=test")!
        oauth.signInURLToReturn = expected
        let result = client.oauthService.makeSignInURL()
        #expect(result == expected)
    }

    // MARK: - transport forwarding (behavioural)

    /// `cancelRun` called via the client returns the transport's actual result
    /// (not a hardcoded default), confirming real forwarding not a stub.
    @Test @MainActor
    func client_cancelRun_returnsTransportResult() async {
        let (client, _, transport) = makeSUT()
        transport.onCancelRun = { _, _ in true }
        let result = await client.transport.cancelRun(runID: 99, scope: "owner/repo")
        #expect(result == true)
    }

    /// When `onCancelRun` is NOT wired, `cancelRun` via the client returns
    /// `false` — confirming the transport's own default propagates through.
    @Test @MainActor
    func client_cancelRun_propagatesTransportDefault() async {
        let (client, _, _) = makeSUT()
        let result = await client.transport.cancelRun(runID: 1, scope: "owner/repo")
        #expect(result == false)
    }

    /// `cancelRun` is forwarded to the mock and the call is recorded.
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

    // MARK: - MockOAuthService stream seams
    //
    // These two tests are kept because they exercise the AsyncStream delivery
    // mechanism that client-facing sign-in/sign-out observers depend on.
    // Pure mock-default tests (isAuthenticated, makeSignInURL, signOut defaults)
    // were removed — those test MockOAuthService itself, not GitHubClient.
    // If mock self-tests are ever needed, add them to MockSanityTests.

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
        // AsyncStream<Void>.AsyncIterator.next() returns Void? — assert non-nil to confirm delivery.
        let value: Void? = await iterator.next()
        #expect(value != nil)
    }
}
