// OAuthSessionCoordinator.swift
// GitHubClient

import Foundation
import OAuthTokenKit

// MARK: - OAuthSessionCoordinator

/// Owns both OAuth callback streams and all transition policy.
///
/// `AppState` constructs and starts the coordinator; views call intent methods
/// (`beginSignIn`, `beginSignOut`, `cancelSignIn`, `reconcileAuthentication`) and
/// render `GitHubAuthentication.oauthState` directly.
///
/// ## Ownership
/// - Subscribes to `OAuthService.makeSignInStream()` and `makeSignOutStream()`.
/// - Holds pre-flow `OAuthState.StableState` for correct rollback on failure.
/// - Applies transition policy: gates duplicate flows, records authoritative success,
///   ignores stray callbacks.
///
/// ## Not observable
/// `OAuthSessionCoordinator` is not `@Observable`. Views continue observing
/// `GitHubAuthentication.oauthState` — the single source of truth.
///
/// ## Task lifetime
/// Task closures use `[weak self]` to avoid a retain cycle
/// (`coordinator → task → closure → coordinator`). The coordinator is released
/// naturally when `AppState` deallocates; `stop()` is not required before dealloc.
@MainActor
public final class OAuthSessionCoordinator {

    // MARK: - Dependencies

    private let service: any OAuthServiceProtocol
    private let authentication: GitHubAuthentication
    private let log: @MainActor (String) -> Void

    // MARK: - Task handles
    //
    // `nonisolated(unsafe)` permits `.cancel()` from Swift 6's nonisolated `deinit`.
    // Task.cancel() is thread-safe. All writes occur on @MainActor inside `start()`
    // and `stop()`. The read in `deinit` happens after the last strong reference
    // drops, so no concurrent write is possible at that point.

    @ObservationIgnored nonisolated(unsafe) private var signInTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var signOutTask: Task<Void, Never>?

    // MARK: - Rollback state

    /// Captured before every sign-in so failures restore the correct prior state.
    private var signInPreviousState: OAuthState.StableState = .signedOut

    // MARK: - Init

    public init(
        service: any OAuthServiceProtocol,
        authentication: GitHubAuthentication,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.service = service
        self.authentication = authentication
        self.log = log
    }

    deinit {
        signInTask?.cancel()
        signOutTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Installs both stream subscriptions. Idempotent — safe to call more than once.
    ///
    /// Both streams are registered synchronously before either `Task` runs so that
    /// any callback dispatched between `start()` returning and the first Task
    /// suspension is already buffered and cannot be missed.
    ///
    /// Call before the first suspension point in `AppState.startObservations()`.
    public func start() {
        // Task-pair invariant: both handles are nil together or non-nil together.
        assert((signInTask == nil) == (signOutTask == nil),
               "OAuthSessionCoordinator: task-pair invariant violated")
        guard signInTask == nil else {
            log("OAuthSessionCoordinator › start() called while already running — ignored")
            return
        }

        // Register streams BEFORE creating tasks so no event can be missed.
        let signInStream = service.makeSignInStream()
        let signOutStream = service.makeSignOutStream()

        signInTask = Task { @MainActor [weak self] in
            for await success in signInStream {
                guard !Task.isCancelled, let self else { return }
                handleSignInEvent(success)
            }
        }

        signOutTask = Task { @MainActor [weak self] in
            for await _ in signOutStream {
                guard !Task.isCancelled, let self else { return }
                handleSignOutEvent()
            }
        }

        log("OAuthSessionCoordinator › started")
    }

    /// Cancels and clears both subscriptions. Idempotent.
    public func stop() {
        assert((signInTask == nil) == (signOutTask == nil),
               "OAuthSessionCoordinator: task-pair invariant violated")
        signInTask?.cancel()
        signInTask = nil
        signOutTask?.cancel()
        signOutTask = nil
        log("OAuthSessionCoordinator › stopped")
    }

    // MARK: - Intents

    /// Initiates the OAuth sign-in flow.
    ///
    /// - Returns: `.started(url)` — caller must open `url` in the browser.
    ///            `.alreadyInProgress` — a flow is already active; ignore.
    ///            `.unavailable` — URL generation failed; flow transitioned to `.failed`.
    @discardableResult
    public func beginSignIn() -> OAuthSignInStartResult {
        guard !isSigningIn, !isSigningOut else {
            log("OAuthSessionCoordinator › beginSignIn — duplicate/concurrent intent ignored")
            return .alreadyInProgress
        }

        // Capture rollback state before any transition.
        signInPreviousState = stableStateBeforeTransition

        guard let url = service.makeSignInURL() else {
            log("OAuthSessionCoordinator › beginSignIn — makeSignInURL returned nil")
            failSignIn("Could not build the GitHub authorization URL.")
            return .unavailable
        }

        authentication.setOAuthState(.signingIn)
        log("OAuthSessionCoordinator › beginSignIn — .signingIn, url=\(url)")
        return .started(url)
    }

    /// Called by the app layer when `NSWorkspace.shared.open(url)` returned `false`.
    public func browserOpeningFailed() {
        guard isSigningIn else { return }
        log("OAuthSessionCoordinator › browserOpeningFailed")
        failSignIn("Could not open GitHub in your browser.")
    }

    /// Cancels an active sign-in flow.
    ///
    /// Immediately transitions to `.failed` (so the UI updates without waiting for
    /// a service event), then calls `service.cancelSignIn()` to invalidate the nonce.
    /// The resulting `false` event from the service is ignored because the state is
    /// already `.failed`.
    public func cancelSignIn() {
        guard isSigningIn else {
            log("OAuthSessionCoordinator › cancelSignIn — not signing in; ignored")
            return
        }
        log("OAuthSessionCoordinator › cancelSignIn — transitioning to .failed then invalidating nonce")
        failSignIn("Sign-in was cancelled.")
        service.cancelSignIn()
    }

    /// Initiates the OAuth sign-out flow.
    public func beginSignOut() {
        guard !isSigningIn, !isSigningOut else {
            log("OAuthSessionCoordinator › beginSignOut — concurrent transition in progress; ignored")
            return
        }
        log("OAuthSessionCoordinator › beginSignOut")
        authentication.setOAuthState(.signingOut(username: currentUsername))
        service.signOut()
    }

    /// Reconciles `oauthState` with the live token store.
    ///
    /// Only `.signingIn` is preserved — a validated browser callback may still be
    /// in flight. All other states are overwritten from Keychain truth.
    public func reconcileAuthentication() {
        guard !isSigningIn else {
            log("OAuthSessionCoordinator › reconcileAuthentication — .signingIn preserved")
            return
        }
        authentication.syncOAuthState(isAuthenticated: service.isAuthenticated)
        log("OAuthSessionCoordinator › reconcileAuthentication — oauthState=\(authentication.oauthState)")
    }

    // MARK: - Computed helpers

    /// `true` while `.signingIn` is the current OAuth state.
    public var isSigningIn: Bool {
        if case .signingIn = authentication.oauthState { return true }
        return false
    }

    /// `true` while `.signingOut` is the current OAuth state.
    public var isSigningOut: Bool {
        if case .signingOut = authentication.oauthState { return true }
        return false
    }

    // MARK: - Policy handlers

    private func handleSignInEvent(_ success: Bool) {
        if success {
            // `true` means OAuthService validated the callback and persisted the token.
            // Do not gate on `.signingIn`: presentation state may have been reconciled
            // or otherwise changed before this event is consumed. `pendingState` is
            // in-memory so a relaunch cannot validate a prior process's nonce.
            authentication.recordOAuthSignIn(username: nil)
        } else if isSigningIn {
            failSignIn("Sign-in was cancelled or failed.")
        } else {
            // Stray false: stable state is already correct, nothing to do.
            log("OAuthSessionCoordinator › signInStream — stray false ignored (state=\(authentication.oauthState))")
            return
        }
        log("OAuthSessionCoordinator › signInStream — success=\(success) → \(authentication.oauthState)")
    }

    private func handleSignOutEvent() {
        // OAuthService deletes the token synchronously before yielding.
        authentication.syncOAuthState(isAuthenticated: service.isAuthenticated)
        log("OAuthSessionCoordinator › signOutStream — → \(authentication.oauthState)")
    }

    private func failSignIn(_ message: String) {
        authentication.setOAuthState(
            .failed(previous: signInPreviousState, message: message)
        )
    }

    private var stableStateBeforeTransition: OAuthState.StableState {
        switch authentication.oauthState {
        case let .signedIn(username):
            return .signedIn(username: username)
        case let .failed(previous, _):
            return previous
        case .signedOut:
            return .signedOut
        case .signingIn, .signingOut:
            assertionFailure("OAuthSessionCoordinator: concurrent OAuth transition was not gated")
            return .signedOut
        }
    }

    private var currentUsername: String? {
        switch stableStateBeforeTransition {
        case let .signedIn(username): username
        case .signedOut: nil
        }
    }
}

// MARK: - OAuthSignInStartResult

/// The result of a `beginSignIn()` call.
public enum OAuthSignInStartResult: Equatable {
    /// Sign-in started. The associated `URL` must be opened in the user's browser.
    case started(URL)
    /// A sign-in or sign-out flow is already in progress; the new request was ignored.
    case alreadyInProgress
    /// The authorization URL could not be constructed. The coordinator has already
    /// transitioned to `.failed`.
    case unavailable
}
