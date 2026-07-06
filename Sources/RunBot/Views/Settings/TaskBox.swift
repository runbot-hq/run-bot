// TaskBox.swift
// RunBot
import Foundation

// MARK: - TaskBox

/// Reference-type wrapper that holds a cancellable polling `Task`.
///
/// `@Observable` expands stored properties via `@ObservationTracked`.
/// Neither `nonisolated` nor plain `nonisolated(unsafe)` on a bare
/// `Task?` property compiles cleanly inside a `@MainActor @Observable`
/// class under Swift 6 strict concurrency — the macro-expanded
/// `_$observationRegistrar` access conflicts.
/// Wrapping the task in a `final class` makes it opaque to the macro,
/// and `deinit` can call `cancel()` without a main-actor hop because
/// `Task` is `Sendable` and `cancel()` is concurrency-safe.
///
/// **Invariant:** `task` must only ever be *written* from `@MainActor`
/// context. `deinit` only *reads* it to call `cancel()`, which is safe
/// because `Task` is `Sendable` and `cancel()` is concurrency-safe.
final class TaskBox: @unchecked Sendable {
    /// The structured polling task, or `nil` before polling has started.
    /// Invariant: must only be written from `@MainActor` context.
    var task: Task<Void, Never>?
    /// Creates an empty `TaskBox` with no active polling task.
    init() {
        // Default property initializers fully define state.
    }
}
