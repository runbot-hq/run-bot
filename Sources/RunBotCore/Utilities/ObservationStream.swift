// ObservationStream.swift
// RunBotCore

import Foundation
import Observation

// MARK: - Internal registration helper

/// Holds the recursive `withObservationTracking` loop for `observationStream(of:)`.
/// Top-level so Swift does not reject it as a generic type nested in a closure.
@MainActor
final class ObservationRegistration<T: Sendable> {
    /// The closure that reads the tracked `@Observable` value on each registration pass.
    private let getValue: @MainActor () -> T
    /// The stream continuation into which each observed value is yielded.
    private let continuation: AsyncStream<T>.Continuation

    /// Creates a new registration with the given value reader and stream continuation.
    /// - Parameters:
    ///   - getValue: A closure that reads one or more `@Observable` properties.
    ///   - continuation: The `AsyncStream` continuation to yield values into.
    init(
        getValue: @escaping @MainActor () -> T,
        continuation: AsyncStream<T>.Continuation
    ) {
        self.getValue = getValue
        self.continuation = continuation
    }

    /// Registers a single `withObservationTracking` pass and schedules the next on change.
    ///
    /// Yields the current value immediately so the consuming `Task` receives an initial
    /// value, then re-registers on the `@MainActor` each time a tracked property changes.
    /// Returns without re-registering if the continuation is already terminated (consuming
    /// task was cancelled).
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
        let registration = ObservationRegistration(getValue: value, continuation: continuation)
        Task { @MainActor in registration.next() }
    }
}
