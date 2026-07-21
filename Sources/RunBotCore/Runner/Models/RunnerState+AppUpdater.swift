// RunnerState+AppUpdater.swift
// RunBotCore

import AppUpdater
import Foundation

// MARK: - UpdateStateProviding conformance

/// Bridges `RunnerState` to the `AppUpdater` library's host-state protocol.
///
/// All UI-facing auto-update state lives on `RunnerState` as `@Observable`
/// properties. `AppUpdater` drives them exclusively through `apply(_:)`;
/// `currentPhase` lets `AppUpdater` read back the current state without
/// importing `RunBotCore`.
///
/// This conformance lives in its own file so the `import AppUpdater`
/// dependency is confined here and `RunnerState.swift` stays free of the
/// library import.
///
/// Note: `RunnerState.swift` now imports `AppUpdater` for the `UpdatePhase`
/// type used by the stored `currentPhase` property. The conformance-only
/// import is still confined to this file; `RunnerState.swift`'s import is
/// the minimal addition required to type the stored property.
extension RunnerState: UpdateStateProviding {

    // MARK: - apply

    /// Advances `RunnerState` to the given `UpdatePhase`.
    ///
    /// Each case maps to a precise set of field mutations:
    ///
    /// | Phase | Fields set |
    /// |---|---|
    /// | `.idle` | all update fields cleared |
    /// | `.available(version)` | `availableUpdate = version`; zip/failure fields cleared |
    /// | `.downloading(version)` | `availableUpdate = version`; zip URL / failure fields cleared |
    /// | `.ready(version)` | `availableUpdate = version`; `cachedUpdateVersion = version`; failure flags cleared |
    /// | `.failed(version)` | `updateActionFailed = true`; zip URL cleared |
    ///
    /// At the end of every case, `self.currentPhase` is assigned the value
    /// returned by `derivedPhase(for:)`. This keeps the stored `currentPhase`
    /// property (tracked by `@Observable`) in sync with the raw fields, so
    /// SwiftUI views that read `currentPhase` are correctly invalidated.
    public func apply(_ phase: UpdatePhase) {
        // DEBUG #2170 — remove once beta-toggle install-button bug is resolved
        #if DEBUG
        log("【RunnerState.apply】phase=\(phase) — previous=\(self.currentPhase)", category: .runner)
        #endif
        switch phase {
        case .idle:
            availableUpdate = nil
            cachedUpdateVersion = nil
            updateActionFailed = false
        case .available(let version):
            availableUpdate = version
            cachedUpdateVersion = nil
            updateActionFailed = false
        case .downloading(let version):
            // Show that a download is in progress: update label visible,
            // cachedUpdateVersion cleared so install button is hidden while downloading.
            availableUpdate = version
            cachedUpdateVersion = nil
            updateActionFailed = false
        case .ready(let version):
            availableUpdate = version
            cachedUpdateVersion = version
            updateActionFailed = false
        case .failed(let version):
            // ✅ REVIEWED: availableUpdate is intentionally preserved when version == nil.
            //
            // The only nil-version caller is the phase-guard path at the top of
            // installAndRelaunch — the `guard case .ready` fails, so .failed(version: nil)
            // is applied. At that point currentPhase was already .ready, which means
            // availableUpdate was already set to the version string. Leaving it in place
            // means the .failed UI still shows the version label and the curl-install
            // fallback URL. Clearing it would silently drop the version from the error
            // state for no benefit.
            //
            // Do NOT change `if let version { availableUpdate = version }` to an
            // unconditional assignment — that would wipe the version on nil and break
            // the .failed UI for the phase-guard case.
            if let version { availableUpdate = version }
            cachedUpdateVersion = nil
            updateActionFailed = true
        }
        // Keep the stored `currentPhase` in sync.
        // `currentPhase` is a stored `@Observable` property on `RunnerState`.
        // Assigning it here — after all raw-field mutations — guarantees that
        // the single observation notification SwiftUI receives reflects the
        // fully-consistent post-transition state. Views reading `currentPhase`
        // are invalidated exactly once per `apply(_:)` call.
        currentPhase = derivedPhase()
        // DEBUG #2170 — remove once beta-toggle install-button bug is resolved
        #if DEBUG
        log("【RunnerState.apply】→ currentPhase=\(self.currentPhase)", category: .runner)
        #endif
    }

    // MARK: - derivedPhase

    /// Derives the canonical `UpdatePhase` from the current raw storage fields.
    ///
    /// Called at the end of every `apply(_:)` case to produce the value
    /// assigned to the stored `currentPhase` property.
    ///
    /// Priority order (highest to lowest):
    /// 1. `.ready` — zip on disk and a version known
    /// 2. `.failed` — an action failure is flagged
    /// 3. `.available`— a version is known but no zip yet
    /// 4. `.idle` — nothing in progress
    ///
    /// ## `.downloading` is intentionally not reconstructable
    ///
    /// `RunnerState` has no `isDownloading: Bool` flag and never will
    /// (Principle 1: no boolean flags). From stored fields, `.downloading`
    /// and `.available` are identical — both have `cachedUpdateVersion == nil`.
    /// This means `derivedPhase()` returns `.available` while a download is
    /// in progress. This is correct and deliberate — see the full rationale
    /// in the original `currentPhase` doc comment.
    ///
    /// ## Private: only `apply(_:)` should call this
    ///
    /// This helper is `private` because nothing outside `apply(_:)` should
    /// derive a phase from raw fields. All external reads go through the
    /// stored `currentPhase` property, which is always up to date after
    /// any `apply(_:)` call.
    private func derivedPhase() -> UpdatePhase {
        if let version = cachedUpdateVersion { return .ready(version: version) }
        // ✅ REVIEWED: .ready is evaluated first. If both cachedUpdateVersion and
        // updateActionFailed are set simultaneously, .ready wins and .failed is
        // suppressed. This is safe only because apply(.failed(...)) always sets
        // cachedUpdateVersion = nil, making the combined state unreachable through
        // the apply(_:) path.
        //
        // WARNING: Any RunBotCore-internal code that writes to cachedUpdateVersion or
        // updateActionFailed directly — bypassing apply(_:) — can produce this
        // combined state and will silently get .ready instead of .failed.
        // Direct mutation of raw storage without going through apply(_:) is
        // not supported and not defended against here.
        if updateActionFailed { return .failed(version: availableUpdate) }
        if let version = availableUpdate { return .available(version: version) }
        return .idle
    }
}
