// ObservationStream.swift
// RunBotCore

import Foundation
import Observation

// MARK: - Internal registration helper

/// Holds the recursive `withObservationTracking` loop for `observationStream(of:)`.
/// Top-level so Swift does not reject it as a generic type nested in a closure.
@MainActor
final class _ObservationRegistration<T: Sendable> {
    private let getValue: @MainActor () -> T
    private let continuation: AsyncStream<T>.Continuation

    init(
        getValue: @escaping @MainActor () -> T,
        continuation: AsyncStream<T>.Continuation
    ) {
        self.getValue = getValue
        self.continuation = continuation
    }

    func next() {
        withObservationTracking {
            _ = continuation.yield(getValue())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .terminated = continuation.yield(getValue()) { return }
                next()
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
        let registration = _ObservationRegistration(getValue: value, continuation: continuation)
        Task { @MainActor in registration.next() }
    }
}
