// OAuthCredentialControllerTests.swift
// GitHubClientTests
//
// Tests for OAuthCredentialController (issue #2481).
// All tests exercise the real production controller via MockOAuthService.

import Foundation
import OAuthTokenKit
@testable import GitHubClient
import Testing

// MARK: - Helpers

/// Bounded polling helper: awaits up to `maxIterations` async yields for
/// `condition` to become true, calling `Task.yield()` between each check.
/// Fails with a descriptive message if the condition never becomes true.
@MainActor
private func pollUntil(
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    maxIterations: Int = 20,
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<maxIterations where !condition() {
        await Task.yield()
    }
    #expect(condition(), sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
}

// MARK: - Suite

@Suite("OAuthCredentialController (#2481)")
@MainActor
struct OAuthCredentialControllerTests {

    // MARK: - Helpers

    /// Builds a fresh controller + dependencies for each test.
    func makeSUT(
        signInURL: URL? = URL(string: "https://github.com/login/oauth/authorize?client_id=test"),
        isAuthenticated: Bool = false
    ) -> (controller: OAuthCredentialController, service: MockOAuthService, auth: GitHubAuthentication) {
        let service = MockOAuthService()
        service.signInURLToReturn = signInURL
        service.isAuthenticated = isAuthenticated
        let auth = GitHubAuthentication(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = OAuthCredentialController(
            service: service,
            authentication: auth
        )
        return (controller, service, auth)
    }

    // MARK: - 1. start() registers one sign-in stream and is idempotent

    @Test("start() registers one sign-in stream and is idempotent")
    func startRegistersOneStream() async {
        let (controller, service, _) = makeSUT()
        controller.start()

        #expect(service.makeSignInStreamCallCount == 1)

        // Second call is idempotent.
        controller.start()
        #expect(service.makeSignInStreamCallCount == 1)
    }

    // MARK: - 2. Successful true records .signedIn and .oauth

    @Test("successful sign-in sets .signedIn and .oauth")
    func successfulSignInSetsSignedIn() async {
        let (controller, service, auth) = makeSUT()
        controller.start()

        service.triggerSignIn(true)
        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 3. false leaves .signedOut unchanged

    @Test("false sign-in leaves .signedOut unchanged")
    func falseSignInLeavesSignedOut() async {
        let (controller, service, auth) = makeSUT()
        controller.start()

        service.triggerSignIn(false)
        // Yield to let the stream deliver.
        await Task.yield()

        #expect(auth.oauthState.isSignedOut)
        #expect(auth.selectedSource == .unauthenticated)
    }

    // MARK: - 4. reconcile() with token present produces .signedIn

    @Test("reconcile with token present sets .signedIn")
    func reconcileWithToken() async {
        let (controller, _, auth) = makeSUT(isAuthenticated: true)

        controller.reconcile()

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 5. reconcile() without token produces .signedOut

    @Test("reconcile without token sets .signedOut")
    func reconcileWithoutToken() async {
        let (controller, _, auth) = makeSUT(isAuthenticated: false)

        controller.reconcile()

        #expect(auth.oauthState.isSignedOut)
        #expect(auth.selectedSource == .unauthenticated)
    }

    // MARK: - 6. signOut() deletes token, reconciles state, and invokes didSignOut

    @Test("signOut deletes token, reconciles state, and invokes didSignOut")
    func signOutClearsState() async {
        let (controller, service, auth) = makeSUT(isAuthenticated: true)
        var didSignOutCalled = false
        controller.didSignOut = { didSignOutCalled = true }

        // Set up signed-in state.
        controller.reconcile()
        #expect(auth.oauthState.isSignedIn)

        // Sign out: clear the token on the mock.
        service.isAuthenticated = false
        await controller.signOut()

        #expect(auth.oauthState.isSignedOut)
        #expect(auth.selectedSource == .unauthenticated)
        #expect(didSignOutCalled)
        #expect(service.signOutCallCount == 1)
    }

    // MARK: - 7. Natural deallocation cancels the subscription

    @Test("deinit cancels the sign-in task")
    func deinitCancelsTask() async {
        let service = MockOAuthService()
        service.signInURLToReturn = URL(string: "https://example.com")
        let auth = GitHubAuthentication(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        do {
            let controller = OAuthCredentialController(
                service: service,
                authentication: auth
            )
            controller.start()
            #expect(service.makeSignInStreamCallCount == 1)
            #expect(service.signInSubscriberCount == 1)
        }
        // Controller deallocated; subscriber should be removed.
        // The deinit cancels signInTask, which terminates the stream,
        // which triggers onTermination, which removes the continuation
        // on the next MainActor yield.
        await pollUntil(maxIterations: 10) { service.signInSubscriberCount == 0 }
    }

    // MARK: - 8. makeSignInURL delegates to service

    @Test("makeSignInURL delegates to service")
    func makeSignInURLDelegates() {
        let (controller, service, _) = makeSUT()

        let url = controller.makeSignInURL()

        #expect(url != nil)
        #expect(service.makeSignInURLCallCount == 1)
    }

    @Test("makeSignInURL returns nil when service returns nil")
    func makeSignInURLReturnsNil() {
        let (controller, service, _) = makeSUT(signInURL: nil)

        let url = controller.makeSignInURL()

        #expect(url == nil)
        #expect(service.makeSignInURLCallCount == 1)
    }
}

// MARK: - OAuthState helpers

private extension OAuthState {
    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    var isSignedOut: Bool {
        if case .signedOut = self { return true }
        return false
    }
}
