// AppDelegate+Polling.swift
// RunBot

import Foundation
import GitHubClient
import RunBotCore

/// AppDelegate extension managing the OAuth sign-out subscription and poll-loop coordination.
extension AppDelegate {

    // MARK: - Sign-out subscription

    /// Restarts the poll loop when the user signs out of OAuth so that
    /// `githubToken()` re-resolves to `GH_TOKEN` / `GITHUB_TOKEN` env vars
    /// on the very next fetch cycle.
    ///
    /// ## Why this lives here and not in SettingsView
    /// `SettingsView`'s `signOutTask` is stored in `@State` and is
    /// only alive while Settings is visible. `AppDelegate` is a true singleton
    /// for the app's lifetime, so this task is always active.
    ///
    /// ## What was broken (regression from PR #1138)
    /// Before #1138, polling was driven by `Timer + scheduleTimer()`. After
    /// sign-out the timer fired, `fetch()` ran, `githubToken()` found the
    /// cache cleared, and naturally fell through to env-var tokens.
    /// #1138 replaced the timer with a `pollTask: Task` that loops on
    /// `Task.sleep` — it never calls `start()` again, so the token fallback
    /// only works if `start()` is explicitly invoked after sign-out.
    func setupSignOutSubscription() {
        signOutTask?.cancel()
        signOutTask = Task { [weak self] in
            // `guard let self` before the loop promotes the weak capture to a strong
            // reference for the entire Task lifetime. AppDelegate is the app-process
            // singleton and is never deallocated while the app is running, so this
            // guard will never actually fire — but it is required to satisfy the
            // compiler's weak-capture rules and makes the nil path explicit.
            // An inner `guard let self` inside the loop body is therefore unnecessary:
            // `self` cannot become nil again once the outer guard has passed.
            guard let self else { return }
            for await _ in oauthService.makeSignOutStream() {
                log("AppDelegate › didSignOut — restarting poll loop for env-token fallback")
                // Two explicit bindings keep nil-self and nil-store distinguishable in
                // logs, and ensure `self` is retained for the full loop iteration.
                // `self?.runnerStore` would conflate both nil paths into one log line
                // and leave `self` unbound for any future code added after `await store.start()`.
                //
                // `return` vs `continue` is deliberate:
                // - `return` for nil self: AppDelegate is gone, the entire Task is meaningless.
                // - `continue` for nil store: AppDelegate is alive; a future sign-out may find
                //   runnerStore set. Keep the stream open and try again on the next event.
                guard let store = self.runnerStore else {
                    log("AppDelegate › didSignOut — ⚠️ runnerStore is nil at sign-out time; skipping start()")
                    continue
                }
                await store.start()
            }
        }
    }
}
