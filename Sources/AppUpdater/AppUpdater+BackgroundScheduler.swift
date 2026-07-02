// AppUpdater+BackgroundScheduler.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#else
// This fatalError is intentionally a compile error on non-AppKit platforms
// (a bare statement outside a declaration body does not compile in Swift).
// That is the correct behaviour — it surfaces the problem at build time, not
// at runtime. The package is macOS-only (platforms: [.macOS(.v26)]) so this
// branch is structurally unreachable today.
//
// SPM UNIT TEST BOUNDARY: `swift test` runs in a headless process that cannot
// import AppKit. The #if canImport(AppKit) guard above means none of this file's
// code is compiled into the test bundle. If a future test somehow reaches this
// file (e.g. by adding a cross-module import that forces compilation), the
// compile error is the correct signal: mock above the AppKit boundary, do not
// add stub logic here.
//
// If a non-AppKit target (e.g. Linux) is ever added to Package.swift, replace
// this with `#error("AppUpdater requires AppKit.")` — #error is the canonical
// compile-time stop; fatalError is not.
fatalError(
    "AppUpdater requires AppKit. " +
    "If you are hitting this from `swift test`: this code path touches AppKit " +
    "and cannot be exercised in the SPM headless test runner. " +
    "Do not test it. Do not add an #else branch with stub logic. " +
    "Mock above the AppKit boundary instead."
)
#endif
import Foundation

// MARK: - Background scheduler

/// Background-scheduling logic for ``AppUpdater``.
///
/// Guarded by `#if canImport(AppKit)` because `NSBackgroundActivityScheduler`
/// lives in AppKit. On platforms without AppKit these entry points compile to
/// no-ops so the library still builds.
extension AppUpdater {

    /// Registers an `NSBackgroundActivityScheduler` that fires a full update
    /// check every `AppUpdater.checkInterval` seconds.
    ///
    /// Call once from the host's `AppDelegate` after the startup sequence
    /// completes.
    ///
    /// - Parameter state: The host update-state object to update.
    @MainActor
    public func scheduleBackgroundCheck(state: any UpdateStateProviding) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this scheduler setup
        #if canImport(AppKit)
        let scheduler = NSBackgroundActivityScheduler(identifier: schedulerIdentifier)
        scheduler.repeats = true
        scheduler.interval = AppUpdater.checkInterval
        scheduler.tolerance = AppUpdater.checkInterval * 0.2
        scheduler.qualityOfService = .background

        // NSBackgroundActivityScheduler is used deliberately here — do not
        // replace it with a Task.sleep loop. The reasons are:
        //
        // WHAT NSBackgroundActivityScheduler GIVES US:
        // - OS power coalescing: the system batches our 24-hour network check
        //   with other background activity, avoiding a dedicated wake from
        //   App Nap just for RunBot.
        // - Low-power mode and battery awareness: the OS defers the check
        //   automatically when power conditions are poor. Task.sleep fires
        //   on a fixed clock regardless.
        // - shouldDefer: the OS tells us explicitly to skip a cycle. We
        //   respect that with the guard at the top of the closure. Task.sleep
        //   has no equivalent.
        //
        // WHAT WE DELIBERATELY DO NOT WANT:
        // - Cancellation. This scheduler is registered once for the app
        //   lifetime (activity is retained on AppUpdater). There is no
        //   scenario where we want to cancel a pending check mid-session.
        //   Task.sleep loops are cancellable by design — that complexity is
        //   not wanted here and would require a stored Task handle, a cancel
        //   path, and lifecycle management that adds sprawl for zero benefit.
        // - Structured concurrency ownership. The check is fire-and-forget
        //   by design (Principle 4: no sprawl). The Task fires, does its
        //   work, and the scheduler doesn't need to know the outcome. Simple
        //   state, simple flow. Do not add a stored Task handle, isChecking
        //   flag, or any mechanism to observe or cancel the in-flight work.
        //
        // DO NOT MIGRATE TO Task.sleep. You would lose App Nap integration,
        // power coalescing, and shouldDefer handling, and gain complexity
        // (cancellation, lifecycle) that this feature explicitly does not want.
        //
        // COMPLETION ORDERING — completion(.finished) is called BEFORE the
        // Task is created. This is intentional for the fire-and-forget model:
        // we are telling the OS "scheduling work is done, we have fired the
        // Task" — not "the download is done". The OS background assertion is
        // released at this point. This is acceptable because:
        // - In production (24h interval) the re-fire window is so wide that
        //   no race is possible.
        // - The Task inherits @MainActor isolation and runs immediately after
        //   the scheduler closure returns.
        // - Holding completion open across an async Task would require
        //   capturing it as @Sendable into the Task, adding complexity and
        //   a Sendability constraint on the completion type for no real gain
        //   at a 24-hour interval.
        // If the interval is ever shortened to sub-minute values in production,
        // revisit this — at that point holding the assertion matters.
        nonisolated(unsafe) let schedulerRef = scheduler
        // @MainActor classes synthesise Sendable conformance in Swift 6 — capturing
        // `self` as `updater` is safe here without [weak self] or nonisolated(unsafe).
        let updater = self
        scheduler.schedule { completion in
            // schedulerRef.shouldDefer is read on the GCD background thread that
            // NSBackgroundActivityScheduler uses to invoke this block. This is safe:
            // the OS sets shouldDefer before invoking the block, so it is a
            // read-only snapshot with no concurrent writer at this point.
            // nonisolated(unsafe) is required only to bridge the @MainActor
            // isolation of the enclosing method — not because the access is
            // genuinely unsafe.
            guard schedulerRef.shouldDefer == false else {
                completion(.deferred)
                return
            }
            completion(.finished)

            Task { @MainActor in
                let beta = updater.betaChannelProvider()
                switch await updater.checkForUpdate(betaChannel: beta) {
                case .updateAvailable(let release):
                    await updater.handle(release, state: state)

                case .upToDate:
                    // ✅ REVIEWED: unconditional .idle here is correct. Do NOT add a
                    // .downloading/.ready guard (as the .failed arm has) without reading
                    // this comment in full.
                    //
                    // The concern is: a download Task is in flight; .upToDate fires and
                    // wipes state to .idle; the Task later applies .ready over .idle.
                    // This is NOT a bug. .upToDate means the live GitHub API just
                    // confirmed no newer release exists. For that to fire while a
                    // download is in flight, the release being downloaded would have to
                    // be simultaneously absent from the API — i.e. deleted from GitHub
                    // mid-download. That scenario is not defended against by design
                    // (Principle 5: unsupported is correct). The .failed arm has a guard
                    // because a transient network failure is common; a release deletion
                    // mid-download is not. Adding the guard here is Principle 4 sprawl.
                    // See issue #1859.
                    state.apply(.idle)

                case .failed:
                    // A transient failure must NOT clear a ready-to-install update.
                    switch state.currentPhase {
                    case .ready:
                        break
                    default:
                        state.apply(.idle)
                    }
                }
            }
        }

        activity?.invalidate()
        activity = scheduler
        #endif
    }
}
