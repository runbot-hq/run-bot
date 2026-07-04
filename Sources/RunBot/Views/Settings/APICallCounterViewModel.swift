// APICallCounterViewModel.swift
// RunBot
//
// @Observable view-model exposing live GitHub API call-counter state
// for the Settings panel (P2 — Async/Await and @Observable for Data Flow).
import Foundation
import GitHubClient
import Observation
import RunBotCore
import SwiftUI

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
private final class TaskBox: @unchecked Sendable {
    /// The structured polling task, or `nil` before polling has started.
    /// Invariant: must only be written from `@MainActor` context.
    var task: Task<Void, Never>?
    /// Creates an empty `TaskBox` with no active polling task.
    init() {
        // Default property initializers fully define state.
    }
}

// MARK: - APICallCounterViewModel

/// View-model that polls `APICallCounterProtocol` every `pollingInterval` and
/// exposes derived display state for `APICallCounterRow`.
///
/// Polling is **not** started automatically at init. Call `startPolling()` when
/// the owning view appears and `stopPolling()` when it disappears, so the
/// background Task does not run while Settings is off screen.
/// `APICallCounterRow` wires this via the `.counterPolling()` view modifier.
@Observable
@MainActor
public final class APICallCounterViewModel {
    /// Interval between counter refreshes.
    private static let pollingInterval: Duration = .seconds(5)

    /// Latest atomic snapshot from the counter actor.
    public private(set) var snap = APICallCounterSnapshot(
        count: 0,
        limit: APICallCounter.hourlyLimit
    )

    /// The counter actor injected at init time (P7).
    private let counter: any APICallCounterProtocol

    /// Box holding the structured polling task so `deinit` can cancel it.
    /// `TaskBox` is `Sendable`; `nonisolated(unsafe)` is not needed.
    private let taskBox = TaskBox()

    /// Creates the view-model.
    /// - Parameter counter: Counter to poll. Defaults to `apiCallCounter`.
    public init(counter: any APICallCounterProtocol = apiCallCounter) {
        self.counter = counter
        // Polling is not started here — call startPolling() from onAppear.
    }

    deinit { taskBox.task?.cancel() }

    // MARK: - Lifecycle

    /// Starts the polling loop. Call from `onAppear` or `.counterPolling()`.
    public func startPolling() {
        guard taskBox.task == nil else { return }
        taskBox.task = Task { [weak self] in
            while !Task.isCancelled {
                if let self { self.snap = await self.counter.snapshot() }
                do {
                    try await Task.sleep(for: Self.pollingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// Stops the polling loop. Call from `onDisappear` or `.counterPolling()`.
    public func stopPolling() {
        taskBox.task?.cancel()
        taskBox.task = nil
    }

    // MARK: - Derived display state

    /// Human-readable counter label, e.g. `"410 / 5,000"`.
    public var label: String {
        "\(snap.count.formatted()) / \(snap.limit.formatted())"
    }

    /// Progress bar and counter tint: green → yellow → red as usage rises.
    public var statusColor: Color {
        switch snap.fraction {
        case ..<0.60: .green
        case ..<0.85: .yellow
        default: .red
        }
    }
}
