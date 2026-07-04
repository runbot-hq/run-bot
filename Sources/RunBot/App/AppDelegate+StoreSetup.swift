// AppDelegate+StoreSetup.swift
// RunBot

import AppKit
import GitHubClient
import Observation
import RunBotCore

/// AppDelegate extension wiring app-lifecycle callbacks to store and service setup.
extension AppDelegate {

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    /// - Parameter _: The notification (unused).
    func applicationWillFinishLaunching(_ _: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Entry point after launch. Configures the GitHub API clients, then builds
    /// the status-bar item and NSPopover panel.
    ///
    /// ## Startup ordering
    /// The sequence is:
    ///
    /// 1. Configure transports (synchronous, no actor reads).
    /// 2. Configure `LocalRunnerStore` — must happen before any await so that
    ///    no lazy observation or indirect `.shared` access can fire against an
    ///    unconfigured store. (#1741)
    /// 3. Await `refreshDisplayNames` — hydrates `ScopeEntry.displayName` cache.
    /// 4. `setupStatusItem` / `setupPanel` / `setupSignOutSubscription` — UI and
    ///    observers start only after display names are hydrated.
    ///
    /// ## statusIconTask ordering
    /// `statusIconTask` (Step 13) is assigned in this outer `Task {}` block,
    /// synchronously *after* `setupPanel()` returns but *before* `RunnerPoller.start()`
    /// has a chance to fire. Here is why that ordering is guaranteed:
    ///
    /// `setupPanel → setupSubscriptions` creates the `RunnerPoller` and then
    /// spawns an *inner* `Task(name: "AppDelegate.startup: …")` that suspends on
    /// `await localRunnerStore.refreshAsync()` before calling `store.start()`.
    /// Because `refreshAsync()` suspends, the inner Task yields back to the
    /// `@MainActor` queue — this outer `Task {}` continues to the
    /// `statusIconTask = Task { … }` line before `start()` is ever called.
    /// There is no reachable path where `applyFetchResult` writes to
    /// `runnerState` before `statusIconTask` is registered.
    ///
    /// - Parameter _: The notification (unused).
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")

        // Read the OAuth token directly from Keychain on every call — no cache layer.
        // This replaces the previous `githubToken()` free function which went through
        // GitHubTokenCache. Direct Keychain reads are OS-serialised (Security.framework)
        // so no additional lock is needed. See Keychain.swift P16 rationale.
        configureGHToken { Keychain.token }

        // Wire all three shim transports directly to sharedGitHubTransport,
        // eliminating the intermediate hop through module-level free-function shims.
        // The token is resolved per-call via sharedGitHubTransport's default
        // tokenProvider (githubTokenCore()), which reads the box configured above.
        configureGHAPI { endpoint in
            await sharedGitHubTransport.apiAsync(endpoint)
        }
        configureGHRaw { endpoint in
            await sharedGitHubTransport.raw(endpoint)
        }
        // Both `endpoint` and `timeout` must be forwarded so callers that pass
        // a custom timeout via ghAPIPaginated(endpoint, timeout:) are not silently
        // overridden by apiPaginated's 60-second default.
        configureGHAPIPaginated { endpoint, timeout in
            await sharedGitHubTransport.apiPaginated(endpoint, timeout: timeout)
        }

        // Read knownScopes synchronously before the Task — ScopeStore.shared is
        // @MainActor and we are already on @MainActor here. (#1538)
        let knownScopes = ScopeStore.shared.entries.map(\.scope)
        log("AppDelegate › applicationDidFinishLaunching — startup task starting for \(knownScopes.count) scopes")

        // Hydrate display names, THEN start UI and observers.
        // Plain Task{} inherits @MainActor from AppDelegate; all three setup
        // calls below run on the main actor after the await resolves. (#1538)
        Task {
            // Step 2: configure LocalRunnerStore BEFORE the first await.
            //
            // ⚠️  This call MUST precede refreshDisplayNames.
            // A lazy observation dependency (or any indirect LocalRunnerStore.shared
            // access) can fire during that await. If configure() has not
            // been called yet, LocalRunnerStore.shared fatalErrors immediately.
            //
            // The matching call inside setupSubscriptions() is retained for
            // documentation and structural clarity; its own idempotency guard
            // (guard runnerStore == nil) makes it a no-op when reached. (#1741)
            LocalRunnerStore.configure(viewModel: runnerState)
            log("AppDelegate › applicationDidFinishLaunching — LocalRunnerStore configured")

            // Step 3: hydrate ScopeEntry.displayName from persisted prefs blobs.
            await ScopeStore.shared.refreshDisplayNames()

            // Step 4: start UI and observers — guaranteed to see hydrated prefs.
            setupStatusItem()
            setupPanel()
            setupSignOutSubscription()

            // Step 13: observe aggregateStatus changes via Observations<Value> — the
            // Swift 6.2 native AsyncSequence for @Observable types (Reach Goal #2).
            //
            // Observations handles re-registration, threading, and cancellation
            // correctly at the framework level. No manual withObservationTracking
            // bridge needed.
            //
            // Ordering safety: setupPanel → setupSubscriptions spawns an inner Task
            // that suspends on `await localRunnerStore.refreshAsync()` before calling
            // `store.start()`. The suspension yields control back here, so this
            // assignment is always reached before the first `applyFetchResult` write.
            // See `applicationDidFinishLaunching` doc-comment for the full explanation.
            statusIconTask = Task { @MainActor [weak self] in
                guard let self else { return }
                // Observations has did-set semantics: it emits once immediately with
                // the current value, then on each subsequent change. The initial call
                // seeds the status icon to the correct state at startup.
                for await _ in Observations({ self.runnerState.aggregateStatus }) {
                    updateStatusIcon()
                }
            }

            log("AppDelegate › applicationDidFinishLaunching — DONE")
        }
    }
}
