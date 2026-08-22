// OAuthCredentialControllerTests.swift
// GitHubClientTests
//
// Tests for OAuthCredentialController (issue #2481).
// All tests exercise the real production controller via MockOAuthService.

import Foundation
import OAuthTokenKit
@testable import GitHubClient
import Testing
import XCTest

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
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else {
            fatalError("Failed to create UserDefaults with suite name")
        }
        let auth = GitHubAuthentication(defaults: defaults)
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

    // MARK: - 3. false is ignored and a later success still signs in

    @Test("false is ignored and a later success still signs in")
    func falseIsIgnoredAndLaterSuccessWorks() async {
        let (controller, service, auth) = makeSUT()
        controller.start()

        service.triggerSignIn(false)
        service.triggerSignIn(true)

        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 4. reconcile() tracks authentication state

    @Test("reconcile tracks authentication state")
    func reconcileTracksAuthentication() async {
        let cases: [(isAuthenticated: Bool, expectedSource: GitHubAuthSource)] = [
            (true,  .oauth),
            (false, .unauthenticated),
        ]
        for testCase in cases {
            let (controller, _, auth) = makeSUT(isAuthenticated: testCase.isAuthenticated)
            controller.reconcile()
            #expect(auth.selectedSource == testCase.expectedSource)
            if testCase.isAuthenticated {
                #expect(auth.oauthState.isSignedIn)
            } else {
                #expect(auth.oauthState.isSignedOut)
            }
        }
    }

    // MARK: - 6. signOut() deletes token, reconciles state, then invokes didSignOut

    @Test("signOut deletes token, reconciles state, then invokes didSignOut")
    func signOutClearsStateAndInvokesCallback() async {
        let (controller, service, auth) = makeSUT(isAuthenticated: true)
        var didSignOutCalled = false
        var callbackObservedSignedOut = false

        controller.didSignOut = {
            didSignOutCalled = true
            if case .signedOut = auth.oauthState {
                callbackObservedSignedOut = true
            }
        }

        controller.reconcile()
        #expect(auth.oauthState.isSignedIn)

        service.isAuthenticated = false
        await controller.signOut()

        #expect(service.signOutCallCount == 1)
        #expect(auth.oauthState.isSignedOut)
        #expect(auth.selectedSource == .unauthenticated)
        #expect(didSignOutCalled)
        #expect(callbackObservedSignedOut)
    }


    // MARK: - 7. Natural deallocation cancels the subscription

    @Test("deinit cancels the sign-in task")
    func deinitCancelsTask() async {
        let service = MockOAuthService()
        service.signInURLToReturn = URL(string: "https://example.com")
        guard let defaults = UserDefaults(suiteName: UUID().uuidString) else {
            XCTFail("Failed to create UserDefaults")
            return
        }
        let auth = GitHubAuthentication(defaults: defaults)

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
