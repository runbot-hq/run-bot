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

    /// Holds the structured polling task so `deinit` can cancel it.
    /// Written only from `@MainActor` context; `nonisolated(unsafe)` is safe
    /// because `Task.cancel()` is concurrency-safe and `deinit` only reads
    /// this value to cancel — it never writes it.
    nonisolated(unsafe) private var _task: Task<Void, Never>?

    /// Creates the view-model.
    /// - Parameter counter: Counter to poll. Defaults to `apiCallCounter`.
    public init(counter: any APICallCounterProtocol = apiCallCounter) {
        self.counter = counter
        // Polling is not started here — call startPolling() from onAppear.
    }

    deinit { _task?.cancel() }

    // MARK: - Lifecycle

    /// Starts the polling loop. Call from `onAppear` or `.counterPolling()`.
    public func startPolling() {
        guard _task == nil else { return }
        _task = Task { [weak self] in
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
        _task?.cancel()
        _task = nil
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
