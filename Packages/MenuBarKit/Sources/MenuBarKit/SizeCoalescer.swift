// SizeCoalescer.swift
// MenuBarKit
//
// SwiftUI reports intrinsic-size invalidations in bursts — a single navigation
// can fire three or four in one runloop turn. Applying a window frame for each
// one produced the visible resize stutter seen in the #2279 logs.
//
// At most one apply runs per runloop turn. The apply closure reads the current
// size itself rather than receiving one, so nothing is ever applied from a
// value that was already stale when it was reported. `flush()` drains
// synchronously so the frame is correct *before* the panel is ordered front —
// the user never sees a panel at a stale size.
import Foundation

/// Coalesces bursts of size invalidations into one apply per runloop turn.
@MainActor
final class MBKSizeCoalescer {

    /// `true` while an apply has been scheduled but has not run yet.
    private var scheduled = false

    /// The action that measures and applies the current size.
    private let apply: () -> Void

    /// Creates a coalescer.
    /// - Parameter apply: Invoked on the main actor to measure and apply.
    init(apply: @escaping () -> Void) {
        self.apply = apply
    }

    /// Requests an apply on the next runloop turn, if one is not already pending.
    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }

    /// Applies immediately, on the current turn, and pre-empts any pending apply.
    ///
    /// Called just before `orderFront` so the first frame the user sees is right.
    ///
    /// Note: the `Task` enqueued by a prior `schedule()` call is not cancellable
    /// once posted. `drain()` checks `scheduled` before calling `apply()` so the
    /// already-enqueued Task becomes a no-op after `flush()` clears the flag.
    func flush() {
        drain()
    }

    /// Runs the apply action and clears the scheduled flag.
    /// No-op if `scheduled` is already false (guards against a Task posted by
    /// `schedule()` firing after an intervening `flush()`).
    private func drain() {
        guard scheduled else { return }
        scheduled = false
        apply()
    }
}
