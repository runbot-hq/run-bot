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
    var isSigningOut: Bool {
        if case .signingOut = self { return true }
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

/// Bounded polling helper: awaits up to `maxIterations` async yields for
/// `condition` to become true, calling `Task.yield()` between each check.
/// Fails with a descriptive message if the condition never becomes true.
///
/// Use this instead of hardcoded `Task.yield()` repetitions to avoid flaky
/// timing assumptions.
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
    // The first #expect already failed on the condition above; this is a final check.
    #expect(condition(), sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
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

    /// Helper: start the coordinator, begin a sign-in flow, and assert it started.
    @discardableResult
    func beginSignIn(
        coordinator: OAuthSessionCoordinator,
        service: MockOAuthService
    ) -> OAuthSignInStartResult {
        coordinator.start()
        let result = coordinator.beginSignIn()
        return result
    }

    // MARK: - 1. Task-pair invariant

    @Test("start() installs one subscription per stream")
    func startInstallsOneSubscriptionPerStream() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        await pollUntil { service.makeSignInStreamCallCount == 1 }
        #expect(service.makeSignInStreamCallCount == 1)
        #expect(service.makeSignOutStreamCallCount == 1)
    }

    // MARK: - 2. Idempotent startup

    @Test("calling start() twice installs only one subscription per stream")
    func startIsIdempotent() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        coordinator.start()
        await pollUntil { service.makeSignInStreamCallCount == 1 }
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

    @Test("active triggerSignIn(true) produces .signedIn and selectedSource == .oauth")
    func successfulSignInProducesSignedIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        service.triggerSignIn(true)
        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 5. Authoritative true outside .signingIn

    @Test("valid true from .signedOut is accepted as authoritative")
    func authoritativeTrueFromSignedOut() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()

        // State is .signedOut — service validates callback and emits true.
        service.triggerSignIn(true)
        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    @Test("valid true from .signedIn(username:) is accepted as authoritative")
    func authoritativeTrueFromSignedIn() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()

        // Seed signed-in state, then begin re-auth and emit true.
        auth.recordOAuthSignIn(username: "original")
        _ = coordinator.beginSignIn()

        service.triggerSignIn(true)
        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 6. Stray false

    @Test("stray false from .signedIn is ignored (stable state preserved)")
    func strayFalseIsIgnoredWhenSignedIn() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()

        // Seed signed-in state.
        auth.recordOAuthSignIn(username: "testuser")

        service.triggerSignIn(false)
        await Task.yield()

        // Stray false should not change stable state.
        #expect(auth.oauthState.isSignedIn)
        if case .signedIn(let username) = auth.oauthState {
            #expect(username == "testuser")
        }
    }

    @Test("stray false from .signedOut is ignored (stable state preserved)")
    func strayFalseIsIgnoredWhenSignedOut() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()

        // State is .signedOut — emit false without a signing-in flow.
        service.triggerSignIn(false)
        await Task.yield()

        #expect(auth.oauthState.isSignedOut)
    }

    // MARK: - 7. False during .signingIn

    @Test("false during .signingIn produces .failed(.signedOut)")
    func falseDuringSigningInProducesFailed() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        service.triggerSignIn(false)
        await pollUntil { auth.oauthState.isFailed }

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 8. True during .signingIn

    @Test("true during .signingIn produces .signedIn")
    func trueDuringSigningInProducesSignedIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        service.triggerSignIn(true)
        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 9. Cancel during .signingIn

    @Test("cancelSignIn during .signingIn produces .failed(.signedOut)")
    func cancelDuringSigningInProducesFailed() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.cancelSignIn()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 10. Cancel during re-auth

    @Test("cancelSignIn during re-auth preserves .signedIn(username:) as previous state")
    func cancelDuringReAuthPreservesPrevious() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        _ = coordinator.beginSignIn()

        coordinator.cancelSignIn()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 11. Browser open failure

    @Test("browserOpeningFailed during .signingIn produces .failed(.signedOut)")
    func browserOpeningFailedProducesFailed() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.browserOpeningFailed()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 12. Reconcile during sign-in

    @Test("reconcileAuthentication preserves .signingIn during active flow")
    func reconcilePreservesSigningIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        service.isAuthenticated = false
        coordinator.reconcileAuthentication()

        #expect(auth.oauthState.isSigningIn)
    }

    // MARK: - 13. Sign-out ordering

    @Test("sign-out event sets .signedOut and selectedSource becomes .unauthenticated")
    func signOutEventSetsSignedOut() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()

        // Seed signed-in state.
        auth.recordOAuthSignIn(username: "testuser")
        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)

        // The sign-out stream handler calls syncOAuthState(isAuthenticated: false).
        service.isAuthenticated = false
        service.triggerSignOut()
        await pollUntil { auth.oauthState.isSignedOut }

        #expect(auth.oauthState.isSignedOut)
        #expect(auth.selectedSource == .unauthenticated)
    }

    // MARK: - 14. cancelSignIn() — no pending flow

    @Test("cancelSignIn outside .signingIn is a no-op")
    func cancelSignInOutsideSigningInIsNoOp() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()

        #expect(auth.oauthState.isSignedOut)

        coordinator.cancelSignIn()

        // State unchanged, service not called.
        #expect(service.cancelSignInCallCount == 0)
        #expect(auth.oauthState.isSignedOut)
    }

    // MARK: - 15. Cancel during .signingIn — callback false event ignored

    @Test("cancelSignIn produces immediate .failed; service false event does not overwrite cancellation")
    func cancelProducesFailedAndStrayFalseIsIgnored() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        // Cancel — coordinator transitions to .failed immediately.
        coordinator.cancelSignIn()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
        #expect(auth.oauthState.failedMessage == "Sign-in was cancelled.")

        // The service emits false (from cancelSignIn). Coordinator ignores it
        // because state is already .failed (not .signingIn).
        // Simulate the false event arriving.
        service.triggerSignIn(false)
        await Task.yield()

        // State should remain .failed with the correct previous state.
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
        #expect(auth.oauthState.failedMessage == "Sign-in was cancelled.")
    }

    // MARK: - 16. Multicast: coordinator and AppState sign-out subscriber both receive sign-out

    @Test("sign-out stream is multicast — coordinator and subscriber both receive event")
    func signOutStreamMulticast() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()

        // Seed signed-in state.
        auth.recordOAuthSignIn(username: "testuser")

        // Also create an app-level subscriber.
        let appStream = service.makeSignOutStream()
        var appIter = appStream.makeAsyncIterator()

        service.isAuthenticated = false
        service.triggerSignOut()

        // Both should receive the event.
        let appReceived: Void? = await appIter.next()
        #expect(appReceived != nil)
        await pollUntil { auth.oauthState.isSignedOut }
        #expect(auth.oauthState.isSignedOut)
    }

    // MARK: - 17. Stop / restart

    @Test("stop removes both subscriptions")
    func stopRemovesSubscriptions() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        await pollUntil { service.signInSubscriberCount == 1 }

        coordinator.stop()

        // Allow onTermination handlers (which hop to MainActor via Task) to complete.
        await pollUntil(maxIterations: 5) { service.signInSubscriberCount == 0 }
        await pollUntil(maxIterations: 5) { service.signOutSubscriberCount == 0 }

        #expect(service.signInSubscriberCount == 0)
        #expect(service.signOutSubscriberCount == 0)
    }

    @Test("second stop is harmless")
    func secondStopIsHarmless() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        await pollUntil { service.signInSubscriberCount == 1 }

        coordinator.stop()
        coordinator.stop()

        // Allow onTermination handlers (which hop to MainActor via Task) to complete.
        await pollUntil(maxIterations: 5) { service.signInSubscriberCount == 0 }
        await pollUntil(maxIterations: 5) { service.signOutSubscriberCount == 0 }

        #expect(service.signInSubscriberCount == 0)
        #expect(service.signOutSubscriberCount == 0)
    }

    @Test("restart installs one fresh subscription per stream")
    func restartInstallsFreshSubscriptions() async {
        let (coordinator, service, _) = makeSUT()
        coordinator.start()
        await pollUntil { service.signInSubscriberCount == 1 }

        let initialStreamCallCount = service.makeSignInStreamCallCount

        coordinator.stop()
        coordinator.start()
        await pollUntil { service.signInSubscriberCount == 1 }

        // Fresh subscriptions were created.
        #expect(service.makeSignInStreamCallCount == initialStreamCallCount + 1)
        #expect(service.makeSignOutStreamCallCount == initialStreamCallCount + 1)
    }

    @Test("events are delivered after restart")
    func eventsDeliveredAfterRestart() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        await pollUntil { service.signInSubscriberCount == 1 }

        // Stop and restart.
        coordinator.stop()
        coordinator.start()
        await pollUntil { service.signInSubscriberCount == 1 }

        // Emit a sign-in event after restart.
        service.triggerSignIn(true)
        await pollUntil { auth.oauthState.isSignedIn }

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 18. Natural teardown (weak captures)

    @Test("coordinator releases without retain cycle")
    func naturalTeardown() async {
        let service = MockOAuthService()
        let auth = GitHubAuthentication(defaults: UserDefaults())
        weak var weakCoordinator: OAuthSessionCoordinator?

        do {
            let coordinator = OAuthSessionCoordinator(
                service: service,
                authentication: auth
            )
            weakCoordinator = coordinator
            coordinator.start()
            // Allow task registration to settle.
            await pollUntil { service.signInSubscriberCount == 1 }
            #expect(weakCoordinator != nil)
        }

        // Coordinator released; weak ref should be nil.
        #expect(weakCoordinator == nil)
        // Both subscriptions should have terminated after the bounded yield series.
        // The onTermination handlers run on MainActor via the Task hop.
        await pollUntil(maxIterations: 5) { service.signInSubscriberCount == 0 }
        await pollUntil(maxIterations: 5) { service.signOutSubscriberCount == 0 }
    }

    // MARK: - 19. Duplicate sign-out

    @Test("beginSignOut called twice only calls service.signOut once while .signingOut is active")
    func duplicateSignOutIsIgnored() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()

        // Seed signed-in state.
        auth.recordOAuthSignIn(username: "testuser")

        // First sign-out.
        coordinator.beginSignOut()
        #expect(auth.oauthState.isSigningOut)
        #expect(service.signOutCallCount == 1)

        // Second sign-out while .signingOut is active — should be ignored.
        coordinator.beginSignOut()
        #expect(service.signOutCallCount == 1)
        #expect(auth.oauthState.isSigningOut)
    }

    @Test("beginSignOut during .signingIn is ignored")
    func signOutDuringSigningInIsIgnored() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        #expect(auth.oauthState.isSigningIn)
        #expect(service.signOutCallCount == 0)

        coordinator.beginSignOut()

        // Should be ignored — signing-in is in progress.
        #expect(service.signOutCallCount == 0)
        #expect(auth.oauthState.isSigningIn)
    }

    // MARK: - 20. beginSignIn gated during active flows

    @Test("beginSignIn during .signingIn is rejected")
    func signInDuringSigningInIsRejected() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()
        #expect(auth.oauthState.isSigningIn)

        let second = coordinator.beginSignIn()

        #expect(second == .alreadyInProgress)
        #expect(service.makeSignInURLCallCount == 1)
    }

    @Test("beginSignIn during .signingOut is rejected")
    func signInDuringSigningOutIsRejected() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        coordinator.beginSignOut()
        #expect(auth.oauthState.isSigningOut)

        let result = coordinator.beginSignIn()

        #expect(result == .alreadyInProgress)
        #expect(service.makeSignInURLCallCount == 0)
    }

    // MARK: - 21. browserOpeningFailed calls cancelSignIn

    @Test("browserOpeningFailed calls service.cancelSignIn exactly once")
    func browserOpeningFailedCallsCancelSignIn() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.browserOpeningFailed()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
    }

    // MARK: - 22. browserOpeningFailed exits .signingIn

    @Test("browserOpeningFailed transitions from .signingIn to .failed")
    func browserOpeningFailedExitsSigningIn() async {
        let (coordinator, _, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()
        #expect(auth.oauthState.isSigningIn)

        coordinator.browserOpeningFailed()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 23. Browser-opening failure preserves .signedOut rollback

    @Test("browserOpeningFailure from signedOut preserves signedOut rollback")
    func browserOpeningFailurePreservesSignedOutRollback() async {
        let (coordinator, _, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.browserOpeningFailed()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 24. Browser-opening failure from .signedIn(username:) preserves that rollback state

    @Test("browserOpeningFailure from signedIn preserves signedIn rollback")
    func browserOpeningFailurePreservesSignedInRollback() async {
        let (coordinator, _, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        _ = coordinator.beginSignIn()

        coordinator.browserOpeningFailed()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 25. cancelSignIn calls cancelSignIn exactly once

    @Test("cancelSignIn calls the service exactly once")
    func cancelSignInCallsServiceExactlyOnce() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.cancelSignIn()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
    }

    // MARK: - 26. cancelSignIn from .signedIn re-auth preserves .signedIn(username:) as previous

    @Test("cancelSignIn from re-auth preserves signedIn previous state")
    func cancelSignInFromReAuthPreservesSignedInPrevious() async {
        let (coordinator, _, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        _ = coordinator.beginSignIn()

        coordinator.cancelSignIn()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 27. Rollback: URL unavailable from signedOut

    @Test("URL unavailable from signedOut produces .failed(.signedOut)")
    func urlUnavailableFromSignedOut() async {
        let (coordinator, _, auth) = makeSUT(signInURL: nil)
        coordinator.start()

        let result = coordinator.beginSignIn()

        guard case .unavailable = result else {
            Issue.record("Expected .unavailable")
            return
        }
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 28. Rollback: URL unavailable during re-auth from signedIn

    @Test("URL unavailable during re-auth from signedIn preserves .signedIn(username:) as previous")
    func urlUnavailableFromSignedIn() async {
        let (coordinator, _, auth) = makeSUT(signInURL: nil, isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")

        let result = coordinator.beginSignIn()

        guard case .unavailable = result else {
            Issue.record("Expected .unavailable")
            return
        }
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 29. Rollback: Browser failure from signedOut

    @Test("browser failure from signedOut produces .failed(.signedOut)")
    func browserFailureFromSignedOut() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.browserOpeningFailed()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 30. Rollback: Browser failure during re-auth

    @Test("browser failure during re-auth preserves .signedIn(username:) as previous")
    func browserFailureDuringReAuth() async {
        let (coordinator, _, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        _ = coordinator.beginSignIn()

        coordinator.browserOpeningFailed()

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 31. Rollback: Explicit cancel from signedOut

    @Test("explicit cancel from signedOut produces .failed(.signedOut)")
    func explicitCancelFromSignedOut() async {
        let (coordinator, service, auth) = makeSUT()
        coordinator.start()
        _ = coordinator.beginSignIn()

        coordinator.cancelSignIn()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedOut)
    }

    // MARK: - 32. Rollback: Explicit cancel during re-auth

    @Test("explicit cancel during re-auth preserves .signedIn(username:) as previous")
    func explicitCancelDuringReAuth() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        _ = coordinator.beginSignIn()

        coordinator.cancelSignIn()

        #expect(service.cancelSignInCallCount == 1)
        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 33. Rollback: Callback false during re-auth

    @Test("callback false during re-auth preserves .signedIn(username:) as previous")
    func callbackFalseDuringReAuth() async {
        let (coordinator, service, auth) = makeSUT(isAuthenticated: true)
        coordinator.start()
        auth.recordOAuthSignIn(username: "testuser")
        _ = coordinator.beginSignIn()

        service.triggerSignIn(false)
        await pollUntil { auth.oauthState.isFailed }

        #expect(auth.oauthState.isFailed)
        #expect(auth.oauthState.failedPreviousState == .signedIn(username: "testuser"))
    }

    // MARK: - 34. reconcileAuthentication repairs .signingOut when token is gone

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
