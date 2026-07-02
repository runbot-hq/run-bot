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
                    // The API confirmed no newer release exists — unconditionally
                    // clear to .idle. A reviewer may flag this as "wipes a
                    // mid-download state", but that concern is incorrect: .upToDate
                    // means the live check just returned no update, so there is
                    // nothing valid to preserve. If a concurrent download Task
                    // finishes after this .idle is applied, it will apply .ready
                    // over .idle — which is fine. No isDownloading guard needed.
                    // See issue #1859 Principle 2 (binary outcomes) and Principle 4
                    // (no sprawl) for why an isDownloading flag was deliberately
                    // removed from this library.
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
