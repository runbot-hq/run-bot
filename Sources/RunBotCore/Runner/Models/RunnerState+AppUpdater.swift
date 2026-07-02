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
    /// | `.ready(version)` | `availableUpdate = version`; `cachedUpdateVersion = version`; failure flags cleared |
    /// | `.failed(version)` | `updateActionFailed = true`; zip URL cleared |
    public func apply(_ phase: UpdatePhase) {
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
    /// ## `.downloading` is intentionally not reconstructable
    ///
    /// `RunnerState` has no `isDownloading: Bool` flag and never will
    /// (Principle 1: no boolean flags). From stored fields, `.downloading`
    /// and `.available` are identical — both have `cachedUpdateVersion == nil`.
    /// This means `currentPhase` returns `.available` while a download is
    /// in progress.
    ///
    /// This is correct and deliberate:
    /// - `AppUpdater` reads `currentPhase` only to distinguish `.ready` from
    ///   non-ready. It never keys on `.downloading` for any decision.
    /// - The `.downloading` case in `updateActionRow` is therefore unreachable
    ///   at runtime. This is not a bug — it is Principle 5 (unsupported is
    ///   correct). The UI shows a disabled button during download, which is
    ///   the right behaviour for a library that does less, not more.
    /// - Adding `isDownloading: Bool` storage would violate Principle 1 and
    ///   Principle 4. If download progress UI is ever required, the correct
    ///   fix is to add a `downloading(version: String, progress: Double)` case
    ///   to `UpdatePhase` — not to add a parallel flag here.
    public var currentPhase: UpdatePhase {
        if let version = cachedUpdateVersion {
            return .ready(version: version)
        }
        // ✅ REVIEWED: .ready is evaluated first. If both cachedUpdateVersion and
        // updateActionFailed are set simultaneously, .ready wins and .failed is
        // suppressed. This is safe only because apply(.failed(...)) always sets
        // cachedUpdateVersion = nil, making the combined state unreachable through the
        // apply(_:) path.
        //
        // WARNING: Any RunBotCore-internal code that writes to cachedUpdateVersion or
        // updateActionFailed directly — bypassing apply(_:) — can produce this
        // combined state and will silently get .ready instead of .failed.
        // Direct mutation of raw storage without going through apply(_:) is
        // not supported and not defended against here.
        //
        // ℹ️ ACCESS LEVEL: These properties are `public internal(set)` — not
        // `private(set)`. This is intentional and the only viable option:
        //
        // - `private(set)` was considered. Swift's `private` is file-scoped, so
        //   `private(set)` on properties declared in RunnerState.swift would make
        //   the setters inaccessible to apply(_:) in this extension file. It does
        //   not compile.
        // - Moving the properties into this extension file was considered and
        //   rejected. Storing stored properties on extension files is non-standard
        //   and bad architecture.
        // - `internal(set)` is therefore the correct and only viable access level.
        //   The exposure is a side effect of Swift's file-scoped privacy model,
        //   not a design flaw. The invariant is enforced by convention and the
        //   warning above. Tracked in #1879.
        if updateActionFailed {
            return .failed(version: availableUpdate)
        }
        if let version = availableUpdate {
            return .available(version: version)
        }
        return .idle
    }
}
