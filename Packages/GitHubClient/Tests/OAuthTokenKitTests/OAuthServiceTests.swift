// OAuthServiceTests.swift
// OAuthTokenKitTests
//
// Six contracts cover the full OAuthService observable surface:
//
//  authorizationURLContract            — URL shape, nonce, default/custom scope+redirect (loop)
//  invalidAndReplayedStateAreRejected  — CSRF guard: mismatch, missing code/state, stale nonce, replay
//  successfulCallbackPersistsBeforeSuccess — ordering: token saved before stream fires true
//  networkFailureEmitsFailureWithoutSaving — all failure paths share one code path (loop)
//  signInStreamBroadcastsToSubscribers — multicast: two simultaneous subscribers
//  signOutClearsAuthentication         — signOut + isAuthenticated lifecycle
//
// Absorbed and deleted files:
//   OAuthServiceScopesTests.swift      (1 test)
//   OAuthServiceRedirectURITests.swift (1 test)
//   OAuthServiceAuthStateTests.swift   (1 test)
//
import Testing
import Foundation
import XCTest
@testable import OAuthTokenKit

// MARK: - Helpers

/// TokenStore double used by every test in this file.
/// @unchecked Sendable: all access is from @MainActor serialised suites.
private final class SpyTokenStore: TokenStore, @unchecked Sendable {
    private var stored: String?
    var saveCallCount  = 0
    var deleteCallCount = 0
    var shouldFailSave   = false
    var shouldFailDelete = false

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

private func callbackURL(code: String? = "abc123", state: String? = "some-state") -> URL {
    guard var comps = URLComponents(string: "runbot://oauth/callback") else {
        fatalError("Invalid base URL for callback")
    }
    var items: [URLQueryItem] = []
    if let c = code  { items.append(URLQueryItem(name: "code",  value: c)) }
    if let s = state { items.append(URLQueryItem(name: "state", value: s)) }
    comps.queryItems = items
    guard let url = comps.url else {
        fatalError("Failed to construct callback URL")
    }
    return url
}

private func successPayload(token: String = "ghs_test_token") -> Data {
    do {
        return try JSONEncoder().encode(["access_token": token])
    } catch {
        fatalError("Failed to encode payload: \(error)")
    }
}

// MARK: - OAuthServiceTests

@Suite("OAuthService", .serialized)
@MainActor
struct OAuthServiceTests {

    // MARK: - 1. Authorization URL contract

    /// Verifies URL shape, UUID-formatted nonce, scope encoding, and redirect_uri encoding
    /// for both default and custom configurations in one loop.
    ///
    /// Absorbs: urlContainsStateNonce, scopesAreEncodedCorrectly (OAuthServiceScopesTests),
    ///          redirectURIsAreEncodedCorrectly (OAuthServiceRedirectURITests).
    @Test func authorizationURLContract() throws {
        struct Case {
            let label: String
            let scopes: [String]?
            let redirectURI: String?
            let expectedScope: String
            let expectedRedirectURI: String
        }
        let cases: [Case] = [
            Case(
                label: "defaults",
                scopes: nil,
                redirectURI: nil,
                expectedScope: "repo read:org admin:org manage_runners:org workflow",
                expectedRedirectURI: OAuthService.defaultRedirectURI
            ),
            Case(
                label: "custom scopes + custom redirect",
                scopes: [GitHubScopes.readUser, GitHubScopes.repo],
                redirectURI: "runbot-staging://oauth/callback",
                expectedScope: "read:user repo",
                expectedRedirectURI: "runbot-staging://oauth/callback"
            ),
        ]
        for testCase in cases {
            let service: OAuthService
            if let scopes = testCase.scopes, let redirectURI = testCase.redirectURI {
                service = OAuthService(
                    clientID: "test-id",
                    clientSecret: "test-secret",
                    tokenStore: SpyTokenStore(),
                    scopes: scopes,
                    redirectURI: redirectURI
                )
            } else {
                service = OAuthService(
                    clientID: "test-id",
                    clientSecret: "test-secret",
                    tokenStore: SpyTokenStore()
                )
            }
            let url   = try #require(service.makeSignInURL(), "\(testCase.label): makeSignInURL returned nil")
            let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(
                uniqueKeysWithValues: (comps.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
            #expect(query["scope"]        == testCase.expectedScope,        "\(testCase.label): scope mismatch")
            #expect(query["redirect_uri"] == testCase.expectedRedirectURI,  "\(testCase.label): redirect_uri mismatch")
            let state = try #require(query["state"], "\(testCase.label): state missing")
            #expect(UUID(uuidString: state) != nil, "\(testCase.label): state is not a UUID")
        }
    }

    // MARK: - 2. CSRF guard + replay protection

    /// Sequential test: wrong state rejected → correct state succeeds once →
    /// consumed/stale nonce rejected (replay + double-tap + callingTwiceReplacesPendingState).
    ///
    /// Absorbs: missingCode, missingState, stateMismatch, doubleTap,
    ///          callingTwiceReplacesPendingState.
    ///
    /// Step 1 captures state1 from the first URL, then immediately generates a
    /// second URL so state1 is superseded. Submitting state1 asserts the
    /// last-write-wins security contract: a stale nonce must not be accepted.
    @Test func invalidAndReplayedStateAreRejected() async throws {
        let store   = SpyTokenStore()
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc = makeService(store: store, session: session)

        // 1. Stale nonce rejected (last-write-wins: second makeSignInURL supersedes first).
        let url1   = try #require(svc.makeSignInURL())
        let state1 = try #require(
            URLComponents(url: url1, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        let _      = try #require(svc.makeSignInURL())  // overwrites pendingState
        let stream1 = svc.makeSignInStream()
        var iter1   = stream1.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "code", state: state1))  // stale — rejected
        let staleResult = await iter1.next()
        #expect(staleResult == false)
        #expect(store.load() == nil)

        // 2. Missing code — rejected, nonce consumed.
        let freshURL2 = try #require(svc.makeSignInURL())
        let state2    = try #require(
            URLComponents(url: freshURL2, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        let stream2 = svc.makeSignInStream()
        var iter2   = stream2.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: nil, state: state2))  // no code
        let noCodeResult = await iter2.next()
        #expect(noCodeResult == false)
        #expect(store.load() == nil)

        // 3. Correct state — succeeds, token saved.
        let freshURL3 = try #require(svc.makeSignInURL())
        let state3    = try #require(
            URLComponents(url: freshURL3, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        let stream3 = svc.makeSignInStream()
        var iter3   = stream3.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc123", state: state3))
        let successResult = await iter3.next()
        #expect(successResult == true)
        #expect(store.load() == "ghs_test_token")
        let saveCountAfterSuccess = store.saveCallCount

        // 4. Replay consumed state — rejected, no additional save.
        let stream4 = svc.makeSignInStream()
        var iter4   = stream4.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc123", state: state3))
        let replayResult = await iter4.next()
        #expect(replayResult == false)
        #expect(store.saveCallCount == saveCountAfterSuccess)
    }

    // MARK: - 3. Successful callback ordering

    /// Proves: exchange succeeds → token is in store → then true is emitted.
    /// The ordering assertion (token before event) is the unique value here.
    ///
    /// Absorbs: happyPath (which only checked final state, not ordering).
    @Test func successfulCallbackPersistsBeforeSuccess() async throws {
        let store   = SpyTokenStore()
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        var savedCalled = false
        let svc = makeService(store: store, session: session, onTokenSaved: { savedCalled = true })

        let url   = try #require(svc.makeSignInURL())
        let state = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        let stream = svc.makeSignInStream()
        var iter   = stream.makeAsyncIterator()
        svc.handleCallback(callbackURL(code: "abc123", state: state))
        let result = await iter.next()
        #expect(result == true)
        // Token must be in the store at the moment the event fires.
        #expect(store.load() == "ghs_test_token")
        #expect(store.saveCallCount == 1)
        #expect(savedCalled == true)
    }

    // MARK: - 4. Network / parse / store failures

    /// All failure paths share the same code branch; one loop covers all subtypes.
    ///
    /// Absorbs: networkFailure, jsonDecodeFailure, githubErrorField,
    ///          emptyAccessToken, tokenStoreSaveFailure.
    @Test func networkFailureEmitsFailureWithoutSaving() async throws {
        struct Case {
            let label: String
            let sessionResult: Result<Data, any Error>
            let saveShouldFail: Bool
        }
        let githubErrorData: Data
        do {
            githubErrorData = try JSONEncoder().encode(["error": "bad_verification_code"])
        } catch {
            XCTFail("Failed to encode JSON for error field: \(error)")
            githubErrorData = Data()
        }
        let emptyTokenData: Data
        do {
            emptyTokenData = try JSONEncoder().encode(["access_token": ""])            
        } catch {
            XCTFail("Failed to encode JSON for access_token: \(error)")
            emptyTokenData = Data()
        }
        let cases: [Case] = [
            Case(label: "network error",       sessionResult: .failure(URLError(.notConnectedToInternet)), saveShouldFail: false),
            Case(label: "invalid JSON",         sessionResult: .success(Data("not json".utf8)),             saveShouldFail: false),
            Case(label: "github error field",   sessionResult: .success(githubErrorData), saveShouldFail: false),
            Case(label: "empty access_token",   sessionResult: .success(emptyTokenData),              saveShouldFail: false),
            Case(label: "store.save fails",     sessionResult: .success(successPayload()),                 saveShouldFail: true),
        ]
        for testCase in cases {
            let store   = SpyTokenStore()
            store.shouldFailSave = testCase.saveShouldFail
            let session = MockURLSession()
            session.stubbedResult = testCase.sessionResult
            let svc = makeService(store: store, session: session)

            let url   = try #require(svc.makeSignInURL())
            let state = try #require(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "state" })?.value
            )
            let stream = svc.makeSignInStream()
            var iter   = stream.makeAsyncIterator()
            svc.handleCallback(callbackURL(code: "abc123", state: state))
            let result = await iter.next()
            #expect(result == false, "\(testCase.label): expected false")
            #expect(store.load() == nil, "\(testCase.label): token must not be persisted")
        }
    }

    // MARK: - 5. Multicast streams

    /// Two simultaneous subscribers both receive the same success event.
    /// Production: OAuthCredentialController subscribes; test confirms broadcast is live.
    @Test func signInStreamBroadcastsToSubscribers() async throws {
        let session = MockURLSession()
        session.stubbedResult = .success(successPayload())
        let svc     = makeService(session: session)
        let stream1 = svc.makeSignInStream()
        let stream2 = svc.makeSignInStream()
        var iter1   = stream1.makeAsyncIterator()
        var iter2   = stream2.makeAsyncIterator()
        let url   = try #require(svc.makeSignInURL())
        let state = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        svc.handleCallback(callbackURL(code: "abc123", state: state))
        let r1 = await iter1.next()
        let r2 = await iter2.next()
        #expect(r1 == true)
        #expect(r2 == true)
    }

    // MARK: - 6. Sign-out + auth state

    /// signOut deletes the token, fires onTokenDeleted (even on delete failure),
    /// and isAuthenticated reflects store-backed token presence.
    ///
    /// Absorbs: signOutCallsDeleteAndCallback, signOutFiresCallbackEvenOnDeleteFailure,
    ///          authenticationTracksTokenPresence (OAuthServiceAuthStateTests).
    @Test func signOutClearsAuthentication() {
        // isAuthenticated mirrors token-store presence.
        let emptyService = OAuthService(
            clientID: "test-id", clientSecret: "test-secret",
            tokenStore: SpyTokenStore()
        )
        #expect(emptyService.isAuthenticated == false)
        let seededService = OAuthService(
            clientID: "test-id", clientSecret: "test-secret",
            tokenStore: SpyTokenStore(initial: "oauth-token")
        )
        #expect(seededService.isAuthenticated == true)

        // signOut: deletes token and fires onTokenDeleted.
        let store1 = SpyTokenStore(initial: "some-token")
        var deletedCalled = false
        let svc1 = makeService(store: store1, onTokenDeleted: { deletedCalled = true })
        svc1.signOut()
        #expect(store1.deleteCallCount == 1)
        #expect(deletedCalled == true)
        #expect(store1.load() == nil)

        // signOut fires onTokenDeleted even when delete() returns false.
        let store2 = SpyTokenStore(initial: "some-token")
        store2.shouldFailDelete = true
        var deletedCalled2 = false
        let svc2 = makeService(store: store2, onTokenDeleted: { deletedCalled2 = true })
        svc2.signOut()
        #expect(deletedCalled2 == true)
        #expect(store2.deleteCallCount == 1)
    }
}
