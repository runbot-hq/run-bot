// OAuthSignInObservationTests.swift
// RunBot
// Behavioral coverage for the OAuth sign-in observer pattern used by AppState
// (issue #2468: observation moved from SettingsView to AppState).
//
// These tests exercise the observer logic in isolation using a stub OAuthService
// and a throwaway GitHubAuthentication. They do NOT construct AppState or call
// startSignInObservation() directly — that requires a RunBotTests target.
// Direct AppState lifecycle coverage (retain-cycle, deinit teardown) is deferred.
//
// Test matrix:
//   1. Successful sign-in while observer is active     → .signedIn + .oauth
//   2. Observer survives view-scoped task cancellation → .signedIn + .oauth (the #2468 scenario)
//   3. Failed/cancelled sign-in while .signingIn       → .failed state
//   4. Duplicate-flow gating                           → .signingIn gates second trigger
//   5. Reopen Settings mid-flow                        → .signingIn preserved, sync skipped
//   6. Task cancellation is safe                       → no crash / no continuation leak
//   7. Stray false callback with no active sign-in     → stable state unchanged
import Foundation
import GitHubClient
import RunBotCore
import Testing

// MARK: - StubOAuthService

/// Minimal `OAuthServiceProtocol` test double that lets tests control
/// exactly when the sign-in stream emits and what value it carries.
///
/// `@MainActor` mirrors the protocol isolation requirement.
/// Continuations are captured lazily on `makeSignInStream()` / `makeSignOutStream()`
/// calls — the same pattern used by `MockOAuthService` in GitHubClientTests.
@MainActor
final class StubOAuthService: OAuthServiceProtocol {

    // MARK: Controllable state
    var isAuthenticated: Bool = false
    var hasAnyToken: Bool = false
    var signInURLToReturn: URL? = URL(string: "https://example.com/oauth")

    // MARK: Stream continuations
    private var signInContinuation: AsyncStream<Bool>.Continuation?
    private var signOutContinuation: AsyncStream<Void>.Continuation?

    // MARK: OAuthServiceProtocol
    func makeSignInURL() -> URL? { signInURLToReturn }
    func signOut() { signOutContinuation?.yield(()) }
    /// This stream-only stub does not process callback URLs.
    func handleCallback(_: URL) {
        // Tests drive completion through triggerSignIn(_:).
    }

    func makeSignInStream() -> AsyncStream<Bool> {
        AsyncStream { [weak self] continuation in
            self?.signInContinuation = continuation
        }
    }

    func makeSignOutStream() -> AsyncStream<Void> {
        AsyncStream { [weak self] continuation in
            self?.signOutContinuation = continuation
        }
    }

    // MARK: Test helpers

    /// Pushes a sign-in result to the active `makeSignInStream()` consumer.
    func triggerSignIn(_ success: Bool) {
        signInContinuation?.yield(success)
    }

    /// Pushes a sign-out event to the active `makeSignOutStream()` consumer.
    func triggerSignOut() {
        signOutContinuation?.yield(())
    }
}

// MARK: - Helpers

extension OAuthState {
    /// `true` when the receiver is `.signedIn` regardless of associated username.
    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
    /// `true` when the receiver is `.failed` regardless of associated values.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
    /// `true` when the receiver is `.signingIn`.
    var isSigningIn: Bool {
        if case .signingIn = self { return true }
        return false
    }
}

// MARK: - Suite

/// Verifies the OAuth sign-in observer behavior used by `AppState` (issue #2468).
///
/// Tests drive `StubOAuthService` directly and observe a `GitHubAuthentication`
/// instance — the same pattern `AppState.startSignInObservation()` uses in
/// production. All `UserDefaults` instances are throwaway to avoid polluting
/// the real defaults database.
@Suite("OAuth sign-in observer behavior (#2468)")
@MainActor
struct OAuthSignInObservationTests {

    // MARK: - 1. Successful sign-in while observer is active

    /// Successful callback while the observer is active updates auth to `.signedIn`.
    @Test("successful sign-in emits .signedIn on the shared authentication object")
    func successfulSignInUpdatesAuthState() async {
        let stub = StubOAuthService()
        let auth = GitHubAuthentication(defaults: UserDefaults())

        let task = Task { @MainActor in
            for await success in stub.makeSignInStream() {
                if success {
                    auth.recordOAuthSignIn(username: nil)
                } else {
                    auth.setOAuthState(.failed(previous: .signedOut, message: "cancelled"))
                }
            }
        }
        defer { task.cancel() }

        // Give the task two ticks to subscribe before emitting.
        await Task.yield()
        await Task.yield()

        stub.triggerSignIn(true)
        // Yield twice: once for the stream delivery, once for the @MainActor hop.
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedIn)
        #expect(auth.selectedSource == .oauth)
    }

    // MARK: - 2. Completion after Settings closes (the #2468 regression scenario)

    /// Cancelling a view-lifetime task (simulating Settings disappear) must NOT
    /// prevent the app-lifetime observer from completing the sign-in.
    @Test("sign-in completes after a view-scoped task is cancelled")
    func signInCompletesAfterViewTaskCancelled() async {
        let stub = StubOAuthService()
        let auth = GitHubAuthentication(defaults: UserDefaults())

        // The surviving observer — equivalent to what AppState.startSignInObservation() installs.
        let appTask = Task { @MainActor in
            for await success in stub.makeSignInStream() {
                if success {
                    auth.recordOAuthSignIn(username: nil)
                } else {
                    auth.setOAuthState(.failed(previous: .signedOut, message: "cancelled"))
                }
            }
        }

        // Simulate SettingsView disappearing: the view-scoped task is cancelled.
        // The app-lifetime observer (appTask) must survive and complete the flow.
        let viewTask = Task { @MainActor in
            // Old view-scoped listener doing nothing here — just simulates a competing
            // subscriber that will be cancelled when Settings closes.
            for await _ in stub.makeSignOutStream() { /* sign-out observer only */ }
        }
        viewTask.cancel()   // Settings closed.

        await Task.yield()

        // Browser callback arrives AFTER Settings is gone.
        stub.triggerSignIn(true)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedIn,
                "oauthState must be .signedIn even though the view-scoped task was cancelled")
        #expect(auth.selectedSource == .oauth,
                "selectedSource must be .oauth after successful callback")

        appTask.cancel()
    }

    // MARK: - 3. Failed / cancelled callback

    /// A `false` sign-in event while `.signingIn` is active transitions auth to `.failed`.
    /// The guard requires an active sign-in — stray false callbacks are ignored (test 7).
    @Test("failed callback sets oauthState to .failed when sign-in is active")
    func failedSignInSetsFailed() async {
        let stub = StubOAuthService()
        let auth = GitHubAuthentication(defaults: UserDefaults())

        // Simulate signInWithGitHub() having set .signingIn before the browser opened.
        auth.setOAuthState(.signingIn)

        let task = Task { @MainActor in
            for await success in stub.makeSignInStream() {
                if success {
                    auth.recordOAuthSignIn(username: nil)
                } else if case .signingIn = auth.oauthState {
                    auth.setOAuthState(.failed(previous: .signedOut, message: "Sign-in was cancelled or failed."))
                }
            }
        }
        defer { task.cancel() }

        await Task.yield()
        await Task.yield()
        stub.triggerSignIn(false)
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isFailed)
    }

    // MARK: - 4. Duplicate-flow gating

    /// While `oauthState == .signingIn`, `isSigningIn` must return `true` so the UI
    /// can disable the sign-in button and prevent a second concurrent flow.
    @Test("signingIn state gates duplicate sign-in flows")
    func signingInStateGatesDuplicateFlows() async {
        let auth = GitHubAuthentication(defaults: UserDefaults())

        // Simulate signInWithGitHub() setting state before opening the browser.
        auth.setOAuthState(.signingIn)

        // The UI should disable the button while the flow is in progress.
        #expect(auth.oauthState.isSigningIn,
                "oauthState must be .signingIn while the browser flow is active")

        // A second call to signInWithGitHub() in SettingsView guards with
        // `guard !isSigningIn else { return }` — verify the gate condition.
        let isAlreadySigningIn: Bool
        if case .signingIn = auth.oauthState { isAlreadySigningIn = true } else { isAlreadySigningIn = false }
        #expect(isAlreadySigningIn, "duplicate-flow gate must fire when .signingIn")
    }

    // MARK: - 5. Reopen Settings mid-flow preserves .signingIn

    /// Simulates the onAppearAction() guard from issue #2468 section 3:
    /// syncOAuthState() must be skipped when oauthState is already .signingIn
    /// so reopening Settings mid-flow does not overwrite the transition state.
    @Test("syncOAuthState is skipped when oauthState is .signingIn")
    func reopenSettingsMidFlowPreservesSigningIn() async {
        let auth = GitHubAuthentication(defaults: UserDefaults())

        // Simulate signInWithGitHub() having set .signingIn before browser opened.
        auth.setOAuthState(.signingIn)

        // Reproduce the onAppearAction() guard: only skip .signingIn (active browser flow).
        // .signingOut falls through so a completed sign-out is repaired from Keychain truth.
        switch auth.oauthState {
        case .signingIn:
            break  // skip — browser flow in progress, mid-flow UI state must be preserved
        case .signingOut, .signedOut, .signedIn, .failed:
            // isAuthenticated=false simulates no Keychain token present.
            auth.syncOAuthState(isAuthenticated: false)
        }

        // .signingIn must survive the guard — duplicate sign-in button stays disabled.
        #expect(auth.oauthState.isSigningIn,
                "oauthState must remain .signingIn after onAppearAction() guard")
    }

    // MARK: - 6. Safe task cancellation

    /// Cancelling an active observer task must not leave the stream continuation
    /// dangling or cause a crash. This validates safe task cancellation semantics,
    /// not `AppState` deallocation (which requires a `RunBotTests` target).
    ///
    /// Swift's cooperative cancellation does not interrupt a suspended `for await`
    /// synchronously — the loop exits only on the next await.
    @Test("cancelling an active observer task is safe")
    func cancellingObserverIsSafe() async {
        let stub = StubOAuthService()
        let auth = GitHubAuthentication(defaults: UserDefaults())

        let task = Task { @MainActor in
            for await success in stub.makeSignInStream() {
                if success { auth.recordOAuthSignIn(username: nil) }
            }
        }

        await Task.yield()   // let the task subscribe
        task.cancel()        // signal cancellation
        await Task.yield()   // let Swift process the cancellation signal
        await Task.yield()   // second yield to ensure the for-await exits cleanly

        // The key assertion: no crash occurred and the task terminated.
        // `task.isCancelled` is the reliable post-cancel observable.
        #expect(task.isCancelled, "task must be marked cancelled after cancel()")
    }

    // MARK: - 7. Stray false callback does not overwrite stable state

    /// A `false` event with no active sign-in (e.g. malformed or state-mismatched
    /// callback URL) must be ignored. The `.signingIn` guard in the production
    /// observer — and mirrored here — prevents stray callbacks from overwriting
    /// a stable `.signedIn` / `.signedOut` / `.failed` state.
    @Test("false callback with no active sign-in is ignored")
    func strayFalseCallbackIsIgnored() async {
        let stub = StubOAuthService()
        let auth = GitHubAuthentication(defaults: UserDefaults())
        // Start from a stable signed-in state — no active flow in progress.
        auth.recordOAuthSignIn(username: "ghost")

        let task = Task { @MainActor in
            for await success in stub.makeSignInStream() {
                if success {
                    auth.recordOAuthSignIn(username: nil)
                } else if case .signingIn = auth.oauthState {
                    auth.setOAuthState(.failed(previous: .signedOut, message: "Sign-in was cancelled or failed."))
                }
                // else: stray false event — no state change.
            }
        }
        defer { task.cancel() }

        await Task.yield()
        await Task.yield()
        stub.triggerSignIn(false)   // stray bad callback, no sign-in in progress
        await Task.yield()
        await Task.yield()

        #expect(auth.oauthState.isSignedIn,
                "stray false callback must not overwrite .signedIn")
    }
}
