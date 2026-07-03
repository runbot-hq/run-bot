// ObservationStream.swift
// RunBotCore

import Foundation
import Observation

/// Returns an `AsyncStream` that yields a new value every time any
/// `@Observable` property read inside `value` changes.
///
/// **How it works**
/// Each iteration calls `withObservationTracking` to register tracking,
/// yields the current value, then suspends. When any tracked property
/// changes the `onChange` callback fires, enqueues a `Task { @MainActor in }`
/// that yields the next value and re-registers tracking — producing an
/// infinite, self-re-registering observation stream.
///
/// **Lifetime**
/// The stream runs until the consuming `Task` is cancelled. No retained
/// object is needed; cancellation is handled by structured concurrency.
///
/// **Threading**
/// `value` is called on the `@MainActor`. The stream is safe to iterate
/// from any `@MainActor`-isolated context.
///
/// **Usage**
/// ```swift
/// statusIconTask = Task { @MainActor in
///     for await _ in observationStream(of: { myState.aggregateStatus }) {
///         updateStatusIcon()
///     }
/// }
/// ```
///
/// - Parameter value: A `@MainActor` closure that reads one or more
///   `@Observable` properties. Re-called after each change to
///   re-register tracking and capture the new value.
/// - Returns: An `AsyncStream` that yields `T` on every change.
public func observationStream<T>(
    of value: @escaping @MainActor () -> T
) -> AsyncStream<T> {
    AsyncStream { continuation in
        @MainActor func next() {
            withObservationTracking {
                continuation.yield(value())
            } onChange: {
                Task { @MainActor in
                    if case .terminated = continuation.yield(value()) { return }
                    next()
                }
            }
        }
        Task { @MainActor in next() }
    }
}
