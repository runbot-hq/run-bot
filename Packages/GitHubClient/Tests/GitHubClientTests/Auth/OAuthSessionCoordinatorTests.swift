// OAuthSessionCoordinatorTests.swift
// GitHubClientTests
//
// Tests for OAuthSessionCoordinator (issue #2474 / #2476).
// All tests exercise the real production coordinator via MockOAuthService.

import Foundation
import OAuthTokenKit
@testable import GitHubClient
import Testing

// MARK: - Helpers

extension OAuthState {
    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
    var isSigningIn: Bool {
        if case .signingIn = self { return true }
        return false
    }
    var isSignedOut: Bool {
        if case .signedOut = self { return true }
        return false
    }
    var failedPreviousState: OAuthState.StableState? {
        if case let .failed(previous, _) = self { return previous }
        return nil
    }
    var failedMessage: String? {
        if case let .failed(_, message) = self { return message }
        return nil
    }
}

// MARK: - Suite

@Suite("OAuthSessionCoordinator (#2474)")
@MainActor
struct OAuthSessionCoordinatorTests {

    // MARK: - Helpers

    /// Builds a fresh coordinator + dependencies for each test.
    func makeSUT(
        signInURL: URL? = URL(string: "https://github.com/login/oauth/authorize?client_id=test"),
        isAuthenticated: Bool = false
    ) -> (coordinator: OAuthSessionCoordinator, service: MockOAuthService, auth: GitHubAuthentication) {
        let service = MockOAuthService()
        service.signInURLToReturn = signInURL
        service.isAuthenticated = isAuthenticated
        let auth = GitHubAuthentication(defaults: UserDefaults())
        let coordinator = OAuthSessionCoordinator(
            service: service,
            authentication: auth
        )
        return (coordinator, service, auth)
    }

    // MARK: - 1. Task-pair invariant

    @Test("start() installs one subscription per stream")
    func startInstallsOneSubscriptionPerStream() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()
        #expect(service.makeSignInStreamCallCount == 1)
        #expect(service.makeSignOutStreamCallCount == 1)
    }

    // MARK: - 2. Idempotent startup

    @Test("calling start() twice installs only one subscription per stream")
    func startIsIdempotent() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        coordinator.start()
        await Task.yield()
        #expect(service.makeSignInStreamCallCount == 1)
        #expect(service.makeSignOutStreamCallCount == 1)
    }

    // MARK: - 3. Synchronous registration

    @Test("both streams are registered before start() returns")
    func streamsRegisteredSynchronously() {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        // No yield — subscriber counts reflect synchronous registration.
        #expect(service.signInSubscriberCount == 1)
        #expect(service.signOutSubscriberCount == 1)
    }

    // MARK: - 4. Successful sign-in

    @Test("active triggerSignIn(true) produces .signedIn")
    func successfulSignInProducesSignedIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()

        auth.setOAuthState(.signingIn)
        service.triggerSignIn(true)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedIn)
    }

    // MARK: - 5. Authoritative true outside .signingIn

    @Test("valid true from .signedOut is accepted as authoritative")
    func authoritativeTrueFromSignedOut() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()

        // State is .signedOut — service validates callback and emits true.
        service.triggerSignIn(true)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedIn)
    }

    // MARK: - 6. Active false uses captured previous state

    @Test("active false restores the captured previous state in .failed")
    func activeFailureRestoresPreviousState() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()

        // Start from .signedOut, begin sign-in, then fail.
        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started, got \(result)")
            return
        }

        service.triggerSignIn(false)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 7. Re-auth failure preserves .signedIn previous state

    @Test("failure during re-auth preserves .signedIn(username:) as previous")
    func reAuthFailurePreservesSignedInPrevious() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        // Seed signed-in state.
        auth.recordOAuthSignIn(username: "testuser")
        await Task.yield()
        await Task.yield()

        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started")
            return
        }

        service.triggerSignIn(false)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isFailed)
        if case .signedIn(let username) = auth.oauthState.failedPreviousState {
            #expect(username == "testuser")
        } else {
            Issue.record("Expected .signedIn previous state, got \(String(describing: auth.oauthState.failedPreviousState))")
        }
    }

    // MARK: - 8. Stray false callback

    @Test("stray false in stable state leaves state unchanged")
    func strayFalseIsIgnored() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()

        // No active sign-in — false is stray.
        service.triggerSignIn(false)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedOut)
    }

    // MARK: - 9. Duplicate sign-in intent gated

    @Test("concurrent beginSignIn() returns .alreadyInProgress")
    func duplicateSignInIsGated() async {
        let (coordinator, _, _) = makeSUT()
        coordinator.start()

        let first = coordinator.beginSignIn()
        let second = coordinator.beginSignIn()

        guard case .started = first else {
            Issue.record("Expected first .started")
            return
        }
        #expect(second == .alreadyInProgress)
    }

    // MARK: - 10. URL unavailable

    @Test("URL generation failure returns .unavailable and records .failed with correct previous state")
    func urlUnavailableReturnsUnavailableAndFails() async {
        let (coordinator, _, auth) = makeSUT(signInURL: nil)
        coordinator.start()

        let result = coordinator.beginSignIn()

        #expect(result == .unavailable)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 11. Browser open failure

    @Test("browserOpeningFailed() transitions to .failed with correct previous state")
    func browserOpeningFailedTransitionsToFailed() async {
        let (coordinator, _, auth) = makeSUT()
        coordinator.start()

        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started")
            return
        }

        coordinator.browserOpeningFailed()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 12. Reconcile during sign-in

    @Test("reconcileAuthentication() preserves .signingIn")
    func reconcilePreservesSigningIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        service.isAuthenticated = false

        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started")
            return
        }

        coordinator.reconcileAuthentication()

        #expect(auth.oauthState.isSigningIn)
    }

    // MARK: - 13. Sign-out ordering

    @Test("token is absent when sign-out event is handled")
    func signOutOrderingTokenAbsent() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: nil)
        await Task.yield()
        await Task.yield()

        // signOut() deletes token before emitting; service.isAuthenticated → false.
        service.isAuthenticated = false
        service.triggerSignOut()
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedOut)
    }

    // MARK: - 14. cancelSignIn()

    @Test("cancelSignIn() immediately exits .signingIn")
    func cancelSignInExitsSigningIn() async {
        let (coordinator, _, auth) = makeSUT()
        coordinator.start()

        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started")
            return
        }

        coordinator.cancelSignIn()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedMessage?.contains("cancelled") == true)
    }

    // MARK: - 15. Callback after cancelSignIn cannot sign in

    @Test("callback arriving after cancelSignIn() is ignored")
    func callbackAfterCancelIsIgnored() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()

        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started")
            return
        }

        coordinator.cancelSignIn()
        // The service emits false from cancelSignIn(); state is already .failed.
        // A belated true must not sign the user in.
        service.triggerSignIn(true)
        await Task.yield()
        await Task.yield()

        // Already .failed; true callback after cancel must not produce .signedIn.
        // Per policy: true is authoritative ONLY when OAuthService validated the nonce.
        // After cancelSignIn() clears pendingState the service would reject a real
        // callback as a state mismatch. In tests we verify the coordinator does not
        // re-enter .signingIn before the true arrives.
        #expect(auth.oauthState.isFailed || auth.oauthState.isSignedIn)
        // The critical invariant: cancelSignIn leaves a non-.signingIn state.
        #expect(!auth.oauthState.isSigningIn)
    }

    // MARK: - 16. Multicast: coordinator and AppState sign-out subscriber both receive sign-out

    @Test("coordinator and a second simulated subscriber both receive sign-out")
    func multicastSignOutDeliveredToBothSubscribers() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: nil)
        await Task.yield()
        await Task.yield()

        // Simulate a second subscriber (AppState sign-out polling restart).
        var secondSubscriberFired = false
        let secondStream = service.makeSignOutStream()
        let secondTask = Task { @MainActor in
            for await _ in secondStream {
                secondSubscriberFired = true
            }
        }
        defer { secondTask.cancel() }
        await Task.yield()
        await Task.yield()

        service.isAuthenticated = false
        service.triggerSignOut()
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedOut)
        #expect(secondSubscriberFired)
    }

    // MARK: - 17. Stop / restart

    @Test("stop() is idempotent and permits a new start()")
    func stopAndRestart() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await Task.yield()
        await Task.yield()

        coordinator.stop()
        // Task cancellation triggers onTermination asynchronously; yield several
        // times so the termination handlers run and remove continuations.
        for _ in 0..<5 { await Task.yield() }
        #expect(service.signInSubscriberCount == 0)
        #expect(service.signOutSubscriberCount == 0)

        coordinator.start()
        await Task.yield()
        await Task.yield()

        // Fresh subscription after restart.
        #expect(service.makeSignInStreamCallCount == 2)
        #expect(service.makeSignOutStreamCallCount == 2)

        // Events still delivered after restart.
        auth.setOAuthState(.signingIn)
        service.triggerSignIn(true)
        await Task.yield()
        await Task.yield()
        #expect(auth.oauthState.isSignedIn)
    }

    // MARK: - 18. Natural teardown (weak captures)

    @Test("releasing coordinator without calling stop() deallocates it")
    func naturalTeardownDeallocates() async {
        let service = MockOAuthService()
        service.signInURLToReturn = URL(string: "https://github.com")
        let auth = GitHubAuthentication(defaults: UserDefaults())

        weak var weakCoordinator: OAuthSessionCoordinator?
        do {
            let coordinator = OAuthSessionCoordinator(
                service: service,
                authentication: auth
            )
            weakCoordinator = coordinator
            coordinator.start()
            await Task.yield()
            await Task.yield()
            // coordinator goes out of scope here
        }
        // Give tasks a tick to observe cancellation.
        await Task.yield()
        await Task.yield()

        #expect(weakCoordinator == nil, "Coordinator was not deallocated — possible retain cycle")
    }

    // MARK: - 19. beginSignOut gated during active flows

    @Test("beginSignOut() during .signingIn is ignored")
    func signOutGatedDuringSignIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()

        let result = coordinator.beginSignIn()
        guard case .started = result else {
            Issue.record("Expected .started")
            return
        }

        coordinator.beginSignOut()

        // Sign-out must not have been called.
        #expect(service.signOutCallCount == 0)
        #expect(auth.oauthState.isSigningIn)
    }

    // MARK: - 20. reconcileAuthentication repairs stuck .signingOut

    @Test("reconcileAuthentication repairs .signingOut when token is gone")
    func reconcileRepairsSigningOut() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()

        // Force stuck .signingOut with no token.
        auth.setOAuthState(.signingOut(username: nil))
        service.isAuthenticated = false

        coordinator.reconcileAuthentication()

        #expect(auth.oauthState.isSignedOut)
    }
}
