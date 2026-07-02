// UpdateStateProviding.swift
// AppUpdater
import Foundation

// MARK: - UpdatePhase

/// The discrete phases of an update lifecycle driven by `AppUpdater`.
///
/// `AppUpdater` advances through these phases as it discovers, downloads,
/// and installs an update. The host conforming to `UpdateStateProviding`
/// receives each transition via `apply(_:)` and maps it to its own UI state.
///
/// ## This enum is complete. Do not add cases.
///
/// The five cases below represent the entire update lifecycle as defined
/// in issue #1859 Principle 3: check → download → verify → cache → install.
/// There is no `.installing`, `.cancellable`, `.paused`, `.retrying`, or
/// `.progress(Double)` case. If a proposed feature requires a new case, the
/// correct response is to question the feature, not extend the enum.
/// Principle 5: unsupported is correct.
public enum UpdatePhase: Equatable {
    /// No update activity — nothing available, nothing in progress.
    case idle
    /// A newer release was found; version is the tag string (e.g. `"v1.2.0"`).
    case available(version: String)
    /// A download is in progress for the given version.
    case downloading(version: String)
    /// Download complete and integrity-verified; zip is cached at `AppUpdater.fixedZipURL`.
    case ready(version: String)
    /// A download or install attempt failed. `version` is the release tag if
    /// known at the time of failure, `nil` otherwise.
    case failed(version: String?)
}

// MARK: - UpdateStateProviding

/// The host-app state model that `AppUpdater` drives while an update is
/// discovered, downloaded, and installed.
///
/// `AppUpdater` owns none of the UI state itself — it mutates a conforming
/// object supplied by the host app (typically an `@Observable @MainActor`
/// view model). The host observes that object to render its own update UI.
///
/// ## Why the whole protocol is `@MainActor`
///
/// The conforming type is expected to be observed by SwiftUI/AppKit, both of
/// which require main-thread access. Annotating the entire protocol (not just
/// individual requirements) is required for Swift 6 strict concurrency: it
/// makes every requirement main-actor isolated so `AppUpdater` (also
/// `@MainActor`) can call them synchronously without cross-actor hops, and it
/// lets conforming `@MainActor` classes satisfy the protocol without extra
/// `nonisolated` juggling.
///
/// ## Single-method mutation via `apply(_:)`
///
/// All state changes go through one named method: `apply(_ phase: UpdatePhase)`.
/// The `UpdatePhase` enum is the exclusive state-transfer type — no raw
/// property setters, no boolean flags, no parallel URL properties. This
/// eliminates TOCTOU-shaped misuse: you cannot set a zip URL without also
/// setting the matching version, because both are encoded in a single
/// `UpdatePhase.ready(version:)` case. Every write site becomes a
/// single `state.apply(.case)` call, making state transitions auditable.
///
/// ## Why the protocol also refines `Sendable`
///
/// `AppUpdater.scheduleBackgroundCheck` captures the host-state existential in an
/// escaping `NSBackgroundActivityScheduler` closure that runs on a background
/// GCD queue. Refining `Sendable` makes `any UpdateStateProviding` safe to carry
/// across that boundary. This costs conformers nothing: every conformer is a
/// reference type isolated to `@MainActor` (the whole protocol is), and
/// global-actor-isolated classes are implicitly `Sendable`.
@MainActor
public protocol UpdateStateProviding: AnyObject, Sendable {

    /// Advance the update state to `phase`.
    ///
    /// `AppUpdater` calls this on the main actor whenever the update lifecycle
    /// moves to a new phase. Implementations should store the phase and notify
    /// any observers (e.g. `@Observable` property, `objectWillChange.send()`).
    ///
    /// ## The seam is one-directional: library writes, host reads.
    ///
    /// This is the only mutation method on this protocol and it will remain
    /// the only one (Principle 6: the library owns the flow, not the host).
    /// Do not add `func cancel()`, `func pause()`, `func retry()`, or
    /// `func reset()` to this protocol. The library owns all phase transitions
    /// — the host is a passive observer that renders whatever phase it receives.
    /// If a proposed feature requires the host to drive a transition, the
    /// correct response is to add a method to `AppUpdater` itself, not to
    /// this protocol.
    func apply(_ phase: UpdatePhase)

    /// The current update phase. `AppUpdater` reads this to make decisions
    /// (e.g. skip resetting to `.idle` if already `.ready`).
    var currentPhase: UpdatePhase { get }
}
