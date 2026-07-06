// ObservationRelay.swift
// RunBotCore
//
// F-35: Generic replacement for PreferencesObserver and ScopesObserver.

import Foundation
import Observation

// MARK: - ObservationRelay

/// A generic, `@MainActor`-isolated relay that drives a recursive
/// `withObservationTracking` loop for a single observed value.
///
/// Each call to `start()` registers one tracking pass. When the observed
/// value changes, the relay yields the new value into `continuation` and
/// immediately re-registers, keeping the stream alive indefinitely.
///
/// **Isolation:** every method is `@MainActor`, so the local `func observe()`
/// inside `start()` is implicitly `@MainActor` — no `@Sendable` annotation is
/// required and no value crosses an isolation boundary.
///
/// **Visibility:** `internal` — cross-file within `RunBotCore` only.
/// `@testable import RunBotCore` exposes it to the test target.
///
/// **Single-registration contract:** `start()` must be called exactly once per
/// relay instance. The recursive re-registration in `onChange` is the only
/// valid second call — it fires from inside the relay itself after the previous
/// pass has already expired. Calling `start()` externally a second time
/// registers a second parallel loop and both yield into the same continuation.
/// No runtime guard is provided: a boolean guard would introduce a worse hazard
/// (async Task scheduling means `isStarted` cannot reset synchronously before
/// the next `@MainActor` turn, causing missed change events and a dead loop).
///
/// - Note: `Element` is constrained to `Sendable` because values are yielded
///   from inside a `Task { @MainActor }` onChange closure, which crosses an
///   actor boundary. Both `TimeInterval` and `[String]` satisfy this.
///
/// - Important: This relay is a **restart-only consumer**. Rapid back-to-back
///   observed-value changes coalesce: if the observed value changes again before
///   the `Task` in `onChange` executes, only the latest value is yielded and all
///   intermediate values are silently dropped. This is intentional and correct
///   for the current use-sites (preference/scope changes that trigger a poll
///   restart). Do **not** use this relay where every intermediate value matters
///   (e.g. audit logging, event counting) — it will silently miss events.
@MainActor
final class ObservationRelay<Element: Sendable> {
    /// Pushes new values into the consumer's `AsyncStream`.
    private let continuation: AsyncStream<Element>.Continuation
    /// Returns the current observed value on the `@MainActor`.
    ///
    /// Captured as a closure so the relay stays generic over both
    /// the store protocol and any transformation (e.g. `TimeInterval(…)` cast).
    ///
    /// - Important: Must be side-effect-free. The apply closure of
    ///   `withObservationTracking` calls `read()` solely to register the
    ///   tracking dependency — its return value is discarded. Any side effects
    ///   in `read` will fire on every re-registration pass, not only on yields.
    private let read: @MainActor () -> Element

    /// Creates a new relay.
    ///
    /// - Parameters:
    ///   - continuation: The `AsyncStream<Element>.Continuation` to yield into.
    ///   - read: A side-effect-free `@MainActor` closure that reads (and
    ///     optionally transforms) the observed value from its source.
    ///     Called once per registration pass (return value discarded) and once
    ///     per change event (return value yielded into the stream).
    init(
        continuation: AsyncStream<Element>.Continuation,
        read: @escaping @MainActor () -> Element
    ) {
        self.continuation = continuation
        self.read = read
    }

    /// Registers a single `withObservationTracking` pass and re-registers on change.
    ///
    /// The inner `observe()` function is a local helper that allows
    /// `withObservationTracking` to be called without capturing `self` in the
    /// apply closure, while still being able to reference it in `onChange`.
    ///
    /// - Important: Must be called exactly once per relay instance. See the
    ///   class-level doc for why no runtime guard is provided.
    func start() {
        func observe() {
            // RETAIN: load-bearing local capture. `continuation` must be captured
            // by value here so it remains reachable after `self` is deallocated.
            // The `guard let self else { continuation.finish() }` path below depends
            // on this capture. Do not remove or inline this line, and do not refactor
            // `observe()` into a method — doing so loses the capture and silently
            // breaks the deallocation path.
            let continuation = self.continuation
            withObservationTracking {
                // Called solely to register the tracking dependency with the
                // Observation framework. Return value is intentionally discarded.
                // `read` must be side-effect-free — see property doc.
                _ = read()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        // The relay has been deallocated. Finish the stream so the
                        // for-await consumer exits cleanly and releases the continuation,
                        // breaking the relay ↔ continuation reference cycle. Without
                        // this the stream stays open and onChange Tasks keep scheduling
                        // after the owning context is gone.
                        continuation.finish()
                        return
                    }
                    // read() is called here rather than captured at onChange time.
                    // If the observed value changes again before this Task executes,
                    // rapid back-to-back changes coalesce — the consumer sees only
                    // the latest value. This is inherited behaviour (present in the
                    // original PreferencesObserver/ScopesObserver) and intentional:
                    // current use-sites are restart-only consumers, so skipping
                    // intermediate values is harmless.
                    self.continuation.yield(self.read())
                    self.start()
                }
            }
        }
        observe()
    }
}

