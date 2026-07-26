// StubShellResolver.swift
// EnvTokenKitTests
import Synchronization
@testable import EnvTokenKit

// MARK: - SendableCounter

/// A thread-safe incrementing counter that can be captured by `@Sendable` closures.
///
/// `Mutex` is noncopyable and therefore cannot be captured by a `@Sendable` closure.
/// Wrapping it in a `final class` gives the closure a reference it can safely share
/// across concurrent execution contexts while still guarding the count with a lock.
final class SendableCounter: @unchecked Sendable {
    /// The mutex-guarded call count.
    private let _count = Mutex<Int>(0)
    /// Atomically increments the counter by one.
    func increment() { _count.withLock { $0 += 1 } }
    /// The current value of the counter.
    var value: Int { _count.withLock { $0 } }
}

// MARK: - countingResolver

/// Returns a shell resolver closure that always returns `result` and
/// increments `counter` on each invocation.
///
/// ## Usage
///     let counter = SendableCounter()
///     let provider = EnvTokenProvider(
///         shellResolver: countingResolver(returning: .failed, counter: counter)
///     )
func countingResolver(
    returning result: ShellTokenResult,
    counter: SendableCounter
) -> @Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult {
    { _ in
        counter.increment()
        return result
    }
}
