// AppUpdater+BackgroundScheduler.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
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

        nonisolated(unsafe) let schedulerRef = scheduler
        let updater = self
        scheduler.schedule { completion in
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
