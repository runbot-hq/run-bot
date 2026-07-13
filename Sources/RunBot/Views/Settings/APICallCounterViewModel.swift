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
    /// `nonisolated(unsafe)` is required here because `@Observable` expands
    /// this into a mutable backing var that `nonisolated` (without `unsafe`)
    /// cannot be applied to. The manual safety guarantee holds: all writes
    /// go through `startPolling()` and `stopPolling()` (both `@MainActor`);
    /// `deinit` only reads to call `Task.cancel()`, which is concurrency-safe.
    /// Suppress the compiler warning with `@ObservationIgnored` so the
    /// `@Observable` macro does not wrap this property at all.
    @ObservationIgnored
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

    // MARK: - Reset date (sourced from RunnerState, no GitHubClient changes needed)

    /// The reset date forwarded from `RunnerState.rateLimitResetDate`, populated
    /// on every poll cycle. Set by the owning view via `APICallCounterRow`.
    public var resetDate: Date?

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

    /// "Resets in N min" / "Resets in N sec" label derived from `resetDate`, or "" when unavailable.
    ///
    /// ## Reactivity
    /// `resetDate` is a stored `var` on an `@Observable` class. SwiftUI tracks reads of
    /// `resetDate` inside `body` (via `vm.resetLabel`), so any change to `resetDate`
    /// automatically triggers a re-render. The redraw is driven by the polling tick that
    /// updates `snap` (and with it `resetDate`) — not by a dedicated `Timer`. No explicit
    /// `@Published` or `Timer` is needed; `@Observable` tracking handles reactivity.
    ///
    /// ## Render cadence
    /// Refreshes on each poll tick (~5 s). The seconds branch can therefore lag by up to
    /// one polling interval — acceptable for a Settings row. A dedicated `Timer` is
    /// intentionally avoided to keep complexity low.
    ///
    /// ## Rounding
    /// Both branches use `ceil` so the label never understates remaining time
    /// (e.g. avoids showing "0 sec" or "1 min" for nearly two minutes).
    public var resetLabel: String {
        guard let resetDate else { return "" }
        let interval = resetDate.timeIntervalSinceNow
        guard interval > 0 else { return "Resetting…" }
        if interval < 60 {
            return "Resets in \(Int(ceil(interval))) sec"
        }
        let minutes = Int(ceil(interval / 60))
        return "Resets in \(minutes) min"
    }
}
