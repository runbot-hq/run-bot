// ObservationStreamTests.swift
// RunBotCoreTests
//
// Unit tests for observationStream(of:).
//
// Invariants tested:
//   1. Stream yields a value when an @Observable property changes.
//   2. Stream yields again on a second mutation (re-registration works).
//   3. Stream does NOT yield after the consuming task is cancelled.
//   4. Stream does NOT yield when an untracked property on the same object changes.
import Foundation
import Observation
import Testing

@testable import RunBotCore

@MainActor
@Observable
final class StreamObservableCounter {
    /// Primary tracked property.
    var count = 0
    /// Second property — used by test 4 to verify that mutating an untracked
    /// property does not trigger a stream yield when only `count` is observed.
    var label = ""
}

// MARK: - Signal helper

/// A single-use async signal that fires when `yield()` is called.
///
/// Replaces `Task.sleep` synchronisation in `ObservationStreamTests`.
/// `observationStream`'s internal `onChange` enqueues a `Task { @MainActor in ... }`;
/// awaiting `Signal.wait()` unblocks the instant that Task calls `yield()` —
/// no wall-clock delay, no CI flakiness.
///
/// **Hang safety:** `yield()` finishes the stream after yielding, so `wait()`
/// always terminates — even if `yield()` is never called (the stream finishes
/// empty and `wait()` returns immediately). A test that calls `await signal.wait()`
/// and expects `fired == 1` will then fail on the `#expect`, not hang.
///
/// **Cancellation safety:** call `cancel()` after `group.cancelAll()` in negative-case
/// `withTaskGroup` races so the losing `signal.wait()` child task can exit.
/// `AsyncStream` iteration is not interrupted by task cancellation alone — without
/// an explicit `finish()`, the cancelled child remains suspended indefinitely.
@MainActor
final class StreamSignal {
    /// The backing continuation; `nil` after the stream is finished.
    private var continuation: AsyncStream<Void>.Continuation?
    /// The stream vended to `wait()` callers.
    private let stream: AsyncStream<Void>

    /// Creates a new unresolved signal.
    init() {
        var cont: AsyncStream<Void>.Continuation?
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// Fires the signal and terminates the stream.
    ///
    /// Finishing the stream after the first yield ensures `wait()` always
    /// unblocks — whether onChange fires (stream yields a value then finishes)
    /// or a regression prevents it (stream finishes empty, `wait()` returns,
    /// the `#expect` on `fired` fails the test correctly rather than hanging CI).
    func yield() {
        continuation?.yield(())
        continuation?.finish()
        continuation = nil
    }

    /// Finishes the stream without yielding a value.
    ///
    /// Call this after `group.cancelAll()` in negative-case `withTaskGroup` races
    /// to ensure the losing `signal.wait()` child task can exit. Without this,
    /// task cancellation alone does not terminate `AsyncStream` iteration and the
    /// cancelled child remains suspended, preventing the task group from draining.
    func cancel() {
        continuation?.finish()
        continuation = nil
    }

    /// Suspends until `yield()` is called, or returns immediately if the
    /// stream has already finished (i.e. `yield()` or `cancel()` was already called).
    func wait() async {
        for await _ in stream { return }
    }
}

@Suite("observationStream")
@MainActor
struct ObservationStreamTests {

    /// Verifies that the stream yields when the observed property (`count`) is mutated.
    @Test("yields when observed property changes")
    func yieldsOnChange() async {
        let counter = StreamObservableCounter()
        var fired = 0
        let signal = StreamSignal()

        let task = Task { @MainActor in
            for await _ in observationStream(of: { counter.count }) {
                fired += 1
                signal.yield()
                break
            }
        }

        // Give the stream time to register its first withObservationTracking pass.
        await Task.yield()
        counter.count = 1
        await signal.wait()
        task.cancel()

        #expect(fired == 1)
    }

    /// Verifies that the stream yields a second time after a second mutation,
    /// confirming that `withObservationTracking` re-registration is working correctly.
    @Test("yields again on second mutation — re-registration works")
    func yieldsOnSecondMutation() async {
        let counter = StreamObservableCounter()
        var fired = 0
        let signal1 = StreamSignal()
        let signal2 = StreamSignal()

        let task = Task { @MainActor in
            for await _ in observationStream(of: { counter.count }) {
                fired += 1
                if fired == 1 { signal1.yield() } else { signal2.yield(); break }
            }
        }

        await Task.yield()
        counter.count = 1
        await signal1.wait()    // wait for first yield + re-registration
        counter.count = 2
        await signal2.wait()    // wait for second yield
        task.cancel()

        #expect(fired == 2)
    }

    /// Verifies that the stream does not yield after the consuming task is cancelled.
    @Test("does not yield after task is cancelled")
    func doesNotYieldAfterCancel() async {
        let counter = StreamObservableCounter()
        var fired = 0
        let signal = StreamSignal()

        let task = Task { @MainActor in
            for await _ in observationStream(of: { counter.count }) {
                fired += 1
                signal.yield()
            }
        }

        await Task.yield()
        task.cancel()
        counter.count = 1

        // Race: 1 ms sleep vs the signal. If the stream yields after cancel,
        // the signal wins and the test fails via the #expect below.
        let raceResult = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: .milliseconds(1))
                return false
            }
            group.addTask {
                await signal.wait()
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            signal.cancel()
            return first
        }

        #expect(fired == 0)
        #expect(raceResult == false, "stream yielded after task was cancelled")
    }

    /// Verifies that the stream does not yield when an untracked property (`label`) is
    /// mutated — only properties accessed inside the `value` closure are tracked.
    @Test("does not yield when an untracked property changes")
    func doesNotYieldForUntrackedProperty() async {
        let counter = StreamObservableCounter()
        var fired = 0
        let signal = StreamSignal()

        let task = Task { @MainActor in
            for await _ in observationStream(of: { counter.count }) {
                fired += 1
                signal.yield()
            }
        }

        await Task.yield()
        counter.label = "hello"

        let signalFired = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: .milliseconds(1))
                return false
            }
            group.addTask {
                await signal.wait()
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            signal.cancel()
            return first
        }

        task.cancel()
        #expect(fired == 0)
        #expect(signalFired == false, "stream yielded for untracked property 'label'")
    }
}
