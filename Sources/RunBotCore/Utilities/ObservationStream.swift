// ObservationStream.swift
// RunBotCore

import Foundation
import Observation

// MARK: - Internal registration helper

/// Holds the recursive `withObservationTracking` loop for `observationStream(of:)`.
/// Top-level so Swift does not reject it as a generic type nested in a closure.
@MainActor
final class ObservationRegistration<T: Sendable> {
    private let getValue: @MainActor () -> T
    private let continuation: AsyncStream<T>.Continuation

    init(
        getValue: @escaping @MainActor () -> T,
        continuation: AsyncStream<T>.Continuation
    ) {
        self.getValue = getValue
        self.continuation = continuation
    }

    /// Registers a single `withObservationTracking` pass.
    ///
    /// The `apply` closure **only reads** `getValue()` to register the
    /// key-path dependency — it never yields. Yielding happens inside the
    /// `onChange` `Task` after verifying the continuation is still live.
    ///
    /// Separating read-for-tracking from read-for-yield means:
    /// - No value is delivered synchronously inside `apply`, so the consumer
    ///   cannot mutate observed state before the tracking pass finishes.
    /// - The `onChange` `Task` is the only place values are yielded, so the
    ///   `.terminated` guard always runs before any yield.
    /// - `getValue()` in `onChange` executes outside any ambient tracking
    ///   context, so it cannot accidentally widen the tracked key-path set.
    func register() {
        withObservationTracking {
            // Read-only: registers key-path access, does NOT yield.
            _ = getValue()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Guard before yield: if the consuming task was cancelled
                // the continuation is already .terminated here.
                guard case .enqueued = continuation.yield(getValue()) else { return }
                register()
            }
        }
    }
}

// MARK: - Public API

/// Returns an `AsyncStream` that yields a new value every time any
/// `@Observable` property read inside `value` changes.
///
/// **Lifetime**
/// The stream runs until the consuming `Task` is cancelled.
/// No retained object is needed; structured concurrency manages lifetime.
///
/// **Threading**
/// `value` is called on the `@MainActor`. Safe to iterate from any
/// `@MainActor`-isolated context.
///
/// **Interim solution**
/// This is a manual bridge over `withObservationTracking`. It will be
/// replaced by the native `Observations<Value>` async sequence
/// (Reach Goal #2) once it stabilises in Swift 6.2.
///
/// **Usage**
/// ```swift
/// statusIconTask = Task { @MainActor in
///     for await _ in observationStream(of: { myState.aggregateStatus }) {
///         updateStatusIcon()
///     }
/// }
/// ```
@MainActor
public func observationStream<T: Sendable>(
    of value: @escaping @MainActor () -> T
) -> AsyncStream<T> {
    AsyncStream { continuation in
        let registration = ObservationRegistration(getValue: value, continuation: continuation)
        Task { @MainActor in registration.register() }
    }
}
