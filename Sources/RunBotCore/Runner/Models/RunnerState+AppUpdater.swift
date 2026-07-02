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
    /// | `.ready(version, zipURL)` | `availableUpdate = version`; `updateZipURL = zipURL`; failure flags cleared |
    /// | `.failed(version)` | `updateActionFailed = true`; zip URL cleared |
    public func apply(_ phase: UpdatePhase) {
        switch phase {
        case .idle:
            availableUpdate = nil
            updateZipURL = nil
            cachedUpdateVersion = nil
            updateActionFailed = false

        case .available(let version):
            availableUpdate = version
            updateZipURL = nil
            cachedUpdateVersion = nil
            updateActionFailed = false

        case .downloading(let version):
            // Show that a download is in progress: update label visible,
            // zip URL cleared so install button is hidden while downloading.
            availableUpdate = version
            updateZipURL = nil
            cachedUpdateVersion = nil
            updateActionFailed = false

        case .ready(let version, let zipURL):
            availableUpdate = version
            updateZipURL = zipURL
            cachedUpdateVersion = version
            updateActionFailed = false

        case .failed(let version):
            // Preserve availableUpdate label if we have a version,
            // so the UI can direct the user to the curl-install fallback.
            if let version { availableUpdate = version }
            updateZipURL = nil
            cachedUpdateVersion = nil
            updateActionFailed = true
        }
    }

    // MARK: - currentPhase

    /// Derives the current `UpdatePhase` from the observable storage fields.
    ///
    /// Priority order (highest to lowest):
    /// 1. `.ready` — zip on disk and a version known
    /// 2. `.failed` — an action failure is flagged
    /// 3. `.available` — a version is known but no zip yet
    /// 4. `.idle` — nothing in progress
    ///
    /// Note: `.downloading` is a transient phase — `RunnerState` has no
    /// dedicated `isDownloading` storage flag after Step 3. From the
    /// host's perspective `.downloading` and `.available` look identical
    /// in stored fields (both have `updateZipURL == nil`); `AppUpdater`
    /// drives `.downloading` via `apply` and reads `currentPhase` only
    /// to distinguish `.ready` from non-ready, so this is correct.
    public var currentPhase: UpdatePhase {
        if let version = cachedUpdateVersion, let zipURL = updateZipURL {
            return .ready(version: version, zipURL: zipURL)
        }
        if updateActionFailed {
            return .failed(version: availableUpdate)
        }
        if let version = availableUpdate {
            return .available(version: version)
        }
        return .idle
    }
}
