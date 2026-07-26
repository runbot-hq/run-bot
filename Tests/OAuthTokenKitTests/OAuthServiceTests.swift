// OAuthServiceTests.swift
// OAuthTokenKitTests

import Testing
import Foundation
@testable import OAuthTokenKit

// MARK: - Helpers

/// `TokenStore` double that can be configured to fail `delete()`, used for best-effort sign-out tests.
/// Safe as `@unchecked Sendable` because all accesses in this file occur from
/// `@MainActor` serialized test suites.
private final class SpyTokenStore: TokenStore, @unchecked Sendable {
    private var stored: String?
    var deleteCallCount = 0
    var saveCallCount = 0
    var shouldFailDelete = false
    var shouldFailSave = false

    init(initial: String? = nil) { stored = initial }

    func load() -> String? { stored }

    func save(_ token: String) -> Bool {
        saveCallCount += 1
        if shouldFailSave { return false }
        stored = token
        return true
    }

    func delete() -> Bool {
        deleteCallCount += 1
        if shouldFailDelete { return false }
        stored = nil
        return true
    }
}

/// Builds a minimal `OAuthService` with test doubles.
@MainActor
private func makeService(
    store: SpyTokenStore = SpyTokenStore(),
    session: MockURLSession = MockURLSession(),
    onTokenSaved: (() -> Void)? = nil,
    onTokenDeleted: (() -> Void)? = nil
) -> OAuthService {
    OAuthService(
        clientID: "test-id",
        clientSecret: "test-secret",
        tokenStore: store,
        session: session,
        onTokenSaved: onTokenSaved,
        onTokenDeleted: onTokenDeleted
    )
}

/// Builds a callback URL mimicking GitHub's OAuth redirect.
private func callbackURL(code: String? = "abc123", state: String? = "some-state") -> URL {
    var comps = URLComponents(string: "runbot://oauth/callback")!
    var items: [URLQueryItem] = []
    if let c = code   { items.append(URLQueryItem(name: "code",  value: c)) }
    if let s = state  { items.append(URLQueryItem(name: "state", value: s)) }
    comps.queryItems = items
    return comps.url!
}

/// JSON-encodes a fake GitHub token-exchange success response.
private func successPayload(token: String = "ghs_test_token") -> Data {
    try! JSONEncoder().encode(["access_token": token])
}

/// JSON-encodes a fake GitHub token-exchange error response.
private func errorPayload(error: String = "bad_verification_code") -> Data {
    try! JSONEncoder().encode(["error": error])
}

// MARK: - makeSignInURL

@Suite("OAuthService — makeSignInURL", .serialized)
@MainActor
struct OAuthServiceMakeSignInURLTests {

    @Test("URL contains a UUID-formatted state nonce")
    func urlContainsStateNonce() throws {
        let svc = makeService()
        let url = try #require(svc.makeSignInURL())
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let state = try #require(comps.queryItems?.first(where: { $0.name == "state" })?.value)
        // UUID().uuidString is 36 chars: 8-4-4-4-12
        #expect(UUID(uuidString: state) != nil)
    }

    @Test("Calling makeSignInURL twice replaces pendingState (last-write-wins)")
    func callingTwiceReplacesPendingState() async throws {
        let store = SpyTokenStore()
        let session = MockURLSession()
        let svc = makeService(store: store, session: session)
        let url1 = try #require(svc.makeSignInURL())
        let url2 = try #require(svc.makeSignInURL())
        let state1 = URLComponents(url: url1, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value
        let state2 = URLComponents(url: url2, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value
        #expect(state1 != state2, "Each call must produce a fresh nonce")
        // state1 is stale — handleCallback hits the state-mismatch guard and fires fireSignIn(false)
        // synchronously before ever reaching exchangeCode. stubbedResult is not set here because
        // the network path is never reached; the rejection happens at the CSRF guard layer.
        let stream = svc.makeSignInStream()
        var iter = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(state: state1)) // stale nonce — rejected at CSRF guard
        let result = await iter.next()
        #expect(result == false)
    }
}

// MARK: - handleCallback CSRF guard

@Suite("OAuthService — handleCallback CSRF guard", .serialized)
@MainActor
struct OAuthServiceCSRFTests {

    @Test("Missing code fires sign-in failure and exhausts the nonce")
    func missingCode() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc = makeService(session: session)
        let url = try #require(svc.makeSignInURL())
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value
        // Regression test: the no-code callback must also clear pendingState,
        // preventing the same nonce from being reused by a later callback.
        // First callback: no code — must fire false and consume the nonce.
        let stream1 = svc.makeSignInStream()
        var iter1 = stream1.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: nil, state: state))
        let result1 = await iter1.next()
        #expect(result1 == false)
        // A fresh stream is required for the second assertion: each makeSignInStream() call
        // creates an independent AsyncStream. iter1 has already consumed its one value above
        // and will not receive any further events — reusing it here would hang indefinitely.
        // Second callback: valid code + same state — nonce must be nil now, so this also fails.
        let stream2 = svc.makeSignInStream()
        var iter2 = stream2.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc", state: state))
        let result2 = await iter2.next()
        #expect(result2 == false, "pendingState must be nil after the codeless callback — nonce must not be reusable")
    }

    @Test("Missing state fires sign-in failure")
    func missingState() async throws {
        let svc = makeService()
        _ = svc.makeSignInURL()
        let stream = svc.makeSignInStream()
        var iter = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc", state: nil))
        let result = await iter.next()
        #expect(result == false)
    }

    @Test("State mismatch fires sign-in failure")
    func stateMismatch() async throws {
        let svc = makeService()
        _ = svc.makeSignInURL()
        let stream = svc.makeSignInStream()
        var iter = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc", state: "wrong-state"))
        let result = await iter.next()
        #expect(result == false)
    }

    @Test("Double-tap: second handleCallback fires failure (pendingState cleared after first)")
    func doubleTap() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc = makeService(session: session)
        let url = try #require(svc.makeSignInURL())
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let state = try #require(comps.queryItems?.first(where: { $0.name == "state" })?.value)

        // First call — legitimate, should succeed
        let stream1 = svc.makeSignInStream()
        var iter1 = stream1.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc", state: state))
        let first = await iter1.next()
        #expect(first == true)

        // Second call with the same state — pendingState is now nil, should fail
        let stream2 = svc.makeSignInStream()
        var iter2 = stream2.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc", state: state))
        let second = await iter2.next()
        #expect(second == false)
    }
}

// MARK: - exchangeCode

@Suite("OAuthService — exchangeCode", .serialized)
@MainActor
struct OAuthServiceExchangeCodeTests {

    private func triggerExchange(session: MockURLSession, store: SpyTokenStore = SpyTokenStore()) async -> (result: Bool, store: SpyTokenStore) {
        let svc = makeService(store: store, session: session)
        guard let url = svc.makeSignInURL(),
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        else {
            Issue.record("makeSignInURL returned nil in triggerExchange helper")
            return (false, store)
        }
        let stream = svc.makeSignInStream()
        var iter = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc123", state: state))
        let result = await iter.next() ?? false
        return (result, store)
    }

    @Test("Happy path: token saved, fireSignIn(true)")
    func happyPath() async throws {
        let store = SpyTokenStore()
        var savedCalled = false
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc = makeService(store: store, session: session, onTokenSaved: { savedCalled = true })
        let url = try #require(svc.makeSignInURL())
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "state" })!.value!
        let stream = svc.makeSignInStream()
        var iter = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc123", state: state))
        let result = await iter.next()
        #expect(result == true)
        #expect(store.load() == "ghs_test_token")
        #expect(savedCalled == true)
    }

    @Test("Network failure fires sign-in failure")
    func networkFailure() async throws {
        let session = MockURLSession()
        session.stubbedResult = .failure(URLError(.notConnectedToInternet))
        let out = await triggerExchange(session: session)
        #expect(out.result == false)
    }

    @Test("JSON decode failure fires sign-in failure")
    func jsonDecodeFailure() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(Data("not json at all".utf8))
        let out = await triggerExchange(session: session)
        #expect(out.result == false)
    }

    @Test("GitHub error field in response fires sign-in failure")
    func githubErrorField() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(errorPayload())
        let out = await triggerExchange(session: session)
        #expect(out.result == false)
    }

    @Test("Empty access_token fires sign-in failure")
    func emptyAccessToken() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(try! JSONEncoder().encode(["access_token": ""]))
        let out = await triggerExchange(session: session)
        #expect(out.result == false)
    }

    @Test("tokenStore.save failure: onTokenSaved NOT called, fireSignIn(false)")
    func tokenStoreSaveFailure() async throws {
        let store = SpyTokenStore()
        store.shouldFailSave = true
        var savedCalled = false
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc = makeService(store: store, session: session, onTokenSaved: { savedCalled = true })
        let url = try #require(svc.makeSignInURL())
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "state" })!.value!
        let stream = svc.makeSignInStream()
        var iter = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc123", state: state))
        let result = await iter.next()
        #expect(result == false)
        #expect(savedCalled == false)
    }
}

// MARK: - signOut

@Suite("OAuthService — signOut", .serialized)
@MainActor
struct OAuthServiceSignOutTests {

    @Test("signOut calls tokenStore.delete and fires onTokenDeleted")
    func signOutCallsDeleteAndCallback() async {
        let store = SpyTokenStore(initial: "some-token")
        var deletedCalled = false
        let svc = makeService(store: store, onTokenDeleted: { deletedCalled = true })
        let stream = svc.makeSignOutStream()
        var iter = stream.makeAsyncIterator()
        svc.signOut()
        _ = await iter.next()
        #expect(store.deleteCallCount == 1)
        #expect(deletedCalled == true)
        #expect(store.load() == nil)
    }

    @Test("signOut emits sign-out stream even when delete() returns false")
    func signOutFiresStreamEvenOnDeleteFailure() async {
        let store = SpyTokenStore(initial: "some-token")
        store.shouldFailDelete = true
        var deletedCalled = false
        let svc = makeService(store: store, onTokenDeleted: { deletedCalled = true })
        let stream = svc.makeSignOutStream()
        var iter = stream.makeAsyncIterator()
        svc.signOut()
        _ = await iter.next()  // must not hang
        #expect(deletedCalled == true)
        #expect(store.deleteCallCount == 1)
    }
}

// MARK: - Multicast streams

@Suite("OAuthService — multicast streams", .serialized)
@MainActor
struct OAuthServiceStreamTests {

    @Test("Two makeSignInStream consumers both receive the fireSignIn value")
    func signInStreamMulticast() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc = makeService(session: session)
        let stream1 = svc.makeSignInStream()
        let stream2 = svc.makeSignInStream()
        var iter1 = stream1.makeAsyncIterator()
        var iter2 = stream2.makeAsyncIterator()
        let url = try #require(svc.makeSignInURL())
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "state" })!.value!
        svc.handleCallback(callbackURL(code: "abc123", state: state))
        let r1 = await iter1.next()
        let r2 = await iter2.next()
        #expect(r1 == true)
        #expect(r2 == true)
    }

    @Test("Two makeSignOutStream consumers both receive the sign-out event")
    func signOutStreamMulticast() async {
        let svc = makeService()
        let stream1 = svc.makeSignOutStream()
        let stream2 = svc.makeSignOutStream()
        var iter1 = stream1.makeAsyncIterator()
        var iter2 = stream2.makeAsyncIterator()
        svc.signOut()
        let r1: Void? = await iter1.next()
        let r2: Void? = await iter2.next()
        #expect(r1 != nil)
        #expect(r2 != nil)
    }
}

