// ObservationStream.swift
// RunBotCore

import Foundation
import Observation

/// Returns an `AsyncStream` that yields a new value every time any
/// `@Observable` property read inside `value` changes.
///
/// **How it works**
/// A `@MainActor`-isolated registration object holds the recursive
/// `withObservationTracking` loop. On each change the `onChange` callback
/// enqueues a `Task { @MainActor in }` that yields the next value and
/// re-registers — producing an infinite, self-re-registering stream.
///
/// **Lifetime**
/// The stream runs until the consuming `Task` is cancelled.
/// No retained object is needed; structured concurrency manages lifetime.
///
/// **Threading**
/// `value` is called on the `@MainActor`. Safe to iterate from any
/// `@MainActor`-isolated context.
///
/// **Usage**
/// ```swift
/// statusIconTask = Task { @MainActor in
///     for await _ in observationStream(of: { myState.aggregateStatus }) {
///         updateStatusIcon()
///     }
/// }
/// ```
public func observationStream<T: Sendable>(
    of value: @escaping @MainActor () -> T
) -> AsyncStream<T> {
    AsyncStream { continuation in
        // Wrap the recursive registration in a @MainActor class so the
        // `next` method reference is actor-isolated and therefore Sendable.
        @MainActor final class Registration<U: Sendable> {
            let value: @MainActor () -> U
            let continuation: AsyncStream<U>.Continuation

            init(value: @escaping @MainActor () -> U, continuation: AsyncStream<U>.Continuation) {
                self.value = value
                self.continuation = continuation
            }

            func next() {
                withObservationTracking {
                    _ = continuation.yield(value())
                } onChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .terminated = continuation.yield(value()) { return }
                        next()
                    }
                }
            }
        }

        let registration = Registration(value: value, continuation: continuation)
        Task { @MainActor in registration.next() }
    }
}
