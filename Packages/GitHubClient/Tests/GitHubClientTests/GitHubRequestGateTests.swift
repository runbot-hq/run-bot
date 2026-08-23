// GitHubRequestGateTests.swift
// GitHubClientTests

import Foundation
import Testing

@testable import GitHubClient

// MARK: - GitHubRequestGate unit tests

/// Unit tests for `GitHubRequestGate` — a cancellation-safe, FIFO semaphore
/// that limits the number of concurrently executing operations.
///
/// Every test uses deterministic synchronisation rather than arbitrary sleeps.
@Suite("GitHubRequestGate")
final class GitHubRequestGateTests {

  // MARK: - Concurrency limit

  /// Verifies that `withPermit` never exceeds the configured limit, even when
  /// many operations are launched concurrently.
  @Test func withPermit_neverExceedsConfiguredLimit() async {
    let gate = GitHubRequestGate(limit: 4)
    let monitor = ConcurrencyMonitor()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 12 {
        group.addTask {
          do {
            try await gate.withPermit {
              await monitor.enter()
              try await Task.sleep(for: .milliseconds(50))
              await monitor.exit()
            }
          } catch {
            // Ignore cancellation errors in this test.
          }
        }
      }
    }

    let maxConcurrent = await monitor.maxConcurrent
    let totalEntered = await monitor.totalEntered
    #expect(maxConcurrent == 4, "Gate should never exceed limit of 4")
    #expect(totalEntered == 12, "All 12 operations should have completed")
  }

  // MARK: - Permit release on throw

  /// Verifies that when an operation throws, its permit is released and a
  /// subsequent operation can acquire the permit.
  @Test func withPermit_releasesPermitWhenOperationThrows() async {
    let gate = GitHubRequestGate(limit: 1)

    do {
      try await gate.withPermit {
        throw TestError.someError
      }
      Issue.record("Expected throw")
    } catch {
      // Expected.
    }

    let result = try? await gate.withPermit { "success" }
    #expect(result == "success")
  }

  // MARK: - Cancelled waiter does not leak permit

  /// Verifies that cancelling a waiting task removes its waiter from the queue
  /// and does not prevent a subsequent task from acquiring the permit.
  ///
  /// Uses `waitingCount` polling (via `eventually`) to confirm the waiter is
  /// enqueued before cancellation, then verifies the waiter was removed and
  /// the cancelled task's closure never executed.
  @Test func withPermit_cancelledWaiterDoesNotLeakPermit() async {
    let gate = GitHubRequestGate(limit: 1)
    let latch = TestLatch()

    // Occupier: holds the single permit and signals when acquired.
    let occupierTask = Task {
      try? await gate.withPermit {
        await latch.signalOccupierAcquired()
        await latch.waitForOccupierRelease()
      }
    }

    await latch.waitForOccupierAcquired()

    // Cancelled waiter: we assert it never executes its closure body.
    // The explicit Task<Void, Error> annotation ensures CancellationError
    // propagates to the task result for assertion — Task { try ... } does
    // infer Error in Swift 6.2+, but being explicit protects against future
    // inference changes.
    let flag = ExecutionFlag()
    let cancelledTask = Task<Void, Error> {
      try await gate.withPermit {
        await flag.markExecuted()
      }
    }

    // Wait until the gate has actually enqueued the waiter.
    await eventually { await gate.waitingCount == 1 }

    // Cancel and await the task — the result should be a CancellationError.
    cancelledTask.cancel()
    let cancelledResult = await cancelledTask.result

    // Verify the gate cleaned up the waiter.
    await eventually { await gate.waitingCount == 0 }

    // Verify the closure never executed.
    #expect(await flag.value == false, "Cancelled waiter's closure must not execute")

    // Verify the task threw CancellationError.
    #expect {
      try cancelledResult.get()
    } throws: { error in
      error is CancellationError
    }

    // Release the occupier.
    await latch.signalReleaseOccupier()
    _ = await occupierTask.result

    // Third task must acquire the permit — proving the cancelled waiter
    // did not leak its slot.
    let result = try? await gate.withPermit { "third" }
    #expect(result == "third")
  }

  // MARK: - FIFO waiter order

  /// Verifies that waiters are resumed in FIFO order when permits become
  /// available.
  ///
  /// Uses `waitingCount` polling (via `eventually`) to confirm each waiter is
  /// enqueued before launching the next one, guaranteeing the gate's waiter
  /// list matches the expected A→B→C order.
  @Test func withPermit_waitersAreResumedInFIFOOrder() async {
    let gate = GitHubRequestGate(limit: 1)
    let order = OrderRecorder()
    let latch = TestLatch()

    // Occupier holds the single permit.
    let occupierTask = Task {
      try? await gate.withPermit {
        await latch.signalOccupierAcquired()
        await latch.waitForOccupierRelease()
      }
    }

    await latch.waitForOccupierAcquired()

    // Enqueue waiter A and wait for it to be in the gate's waiter list.
    let taskA = Task {
      try? await gate.withPermit { await order.record("A") }
    }
    await eventually { await gate.waitingCount == 1 }

    // Enqueue waiter B.
    let taskB = Task {
      try? await gate.withPermit { await order.record("B") }
    }
    await eventually { await gate.waitingCount == 2 }

    // Enqueue waiter C.
    let taskC = Task {
      try? await gate.withPermit { await order.record("C") }
    }
    await eventually { await gate.waitingCount == 3 }

    // Release the occupier — permits will trickle through in FIFO order.
    await latch.signalReleaseOccupier()
    _ = await occupierTask.result
    _ = await taskA.result
    _ = await taskB.result
    _ = await taskC.result

    let recorded = await order.order
    #expect(recorded == ["A", "B", "C"], "Waiters must be resumed in FIFO order, got \(recorded)")
  }
}

// MARK: - Test helpers

/// A simple error type for tests that need a thrown error.
private enum TestError: Error {
  /// A generic test error.
  case someError
}

/// Polls the given condition until it returns `true`, with a bounded timeout
/// so a regression fails rather than hanging indefinitely.
///
/// The condition closure is evaluated every 5 milliseconds, up to a maximum
/// of 400 attempts (2000 ms total). This is used to wait for actor-isolated
/// state to converge without resorting to arbitrary sleeps.
///
/// - Parameter condition: An async closure that returns `true` when the
///   desired state is reached.
private func eventually(
  _ condition: @Sendable @escaping () async -> Bool
) async {
  // Yield once to give concurrent tasks a chance to start before we begin
  // polling — this helps on slower CI runners.
  await Task.yield()
  for _ in 0 ..< 400 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("`eventually` timed out waiting for condition")
}

/// Tracks the maximum number of concurrent in-flight operations and the total
/// number of operations that entered the critical section.
private actor ConcurrencyMonitor {
  /// The current number of in-flight operations.
  private var current = 0
  /// The maximum observed concurrent count.
  private(set) var maxConcurrent = 0
  /// The total number of operations that entered.
  private(set) var totalEntered = 0

  /// Records entry into the critical section.
  func enter() {
    current += 1
    totalEntered += 1
    if current > maxConcurrent { maxConcurrent = current }
  }

  /// Records exit from the critical section.
  func exit() {
    current -= 1
  }
}

/// Records completion order of operations.
private actor OrderRecorder {
  /// The recorded order of operations.
  private(set) var order: [String] = []

  /// Records the given label at the current position.
  func record(_ label: String) {
    order.append(label)
  }
}

/// An actor that safely tracks whether a closure was executed, avoiding
/// the shared-mutable-Boolean race between concurrent tasks.
private actor ExecutionFlag {
  /// Whether the closure has been executed.
  private(set) var value = false

  /// Marks the closure as executed.
  func markExecuted() {
    value = true
  }
}

/// An actor-based latch that provides rendezvous points for coordinating
/// concurrent test tasks.
///
/// Each waiter task calls `waitFor...()` to suspend until the coordinating
/// test calls `signal...()`. Because the latch is an actor, all state
/// mutations are serialised, and the `waitFor...` methods use
/// `withCheckedContinuation` to suspend until the corresponding signal
/// is received.
///
/// This avoids the race condition of `SimplePromise` (where `signal()`
/// before `wait()` installs its continuation loses the signal) and the
/// nondeterminism of `Task.yield()`.
private actor TestLatch {
  /// Whether the occupier has acquired the permit.
  private var occupierAcquired = false
  /// Whether the occupier should be released.
  private var occupierRelease = false

  /// Continuation for occupier-acquired signal.
  private var occupierAcquiredContinuation: CheckedContinuation<Void, Never>?
  /// Continuation for occupier-release signal.
  private var occupierReleaseContinuation: CheckedContinuation<Void, Never>?

  // MARK: Signal methods (called by the task under test)

  /// Signals that the occupier has acquired the permit.
  func signalOccupierAcquired() {
    occupierAcquired = true
    occupierAcquiredContinuation?.resume()
    occupierAcquiredContinuation = nil
  }

  // MARK: Wait methods (called by the coordinating test)

  /// Waits until the occupier has acquired the permit.
  func waitForOccupierAcquired() async {
    guard !occupierAcquired else { return }
    await withCheckedContinuation { occupierAcquiredContinuation = $0 }
  }

  // MARK: Occupier release

  /// Signals that the occupier should be released.
  func signalReleaseOccupier() {
    occupierRelease = true
    occupierReleaseContinuation?.resume()
    occupierReleaseContinuation = nil
  }

  /// Waits until the occupier is told to release.
  func waitForOccupierRelease() async {
    guard !occupierRelease else { return }
    await withCheckedContinuation { occupierReleaseContinuation = $0 }
  }
}

// MARK: - Transport-level integration test

/// Integration test verifying that `GitHubTransport` respects the concurrency
/// limit via the `GitHubRequestGate`.
///
/// Uses `ConcurrencyTrackedStubProtocol` — a `URLProtocol` stub that tracks how
/// many `startLoading` calls are active simultaneously. The transport is
/// configured with `maxConcurrentRequests: 2` and 4 concurrent `execute()` calls
/// are launched. The maximum observed concurrency must be 2.
@Suite("GitHubTransportConcurrencyGate", .serialized)
final class GitHubTransportConcurrencyGateTests {

  /// A `URLProtocol` stub that tracks concurrent `startLoading` calls.
  ///
  /// Every static property is guarded by `lock` to prevent data races.
  /// `reset()` is synchronous and completes all cleanup before returning.
  private final class ConcurrencyTrackedStubProtocol: URLProtocol, @unchecked Sendable {

    /// Actor that tracks the maximum concurrent in-flight requests.
    private actor ConcurrentStubMonitor {
      /// The current number of in-flight requests.
      private var current = 0
      /// The maximum observed concurrent count.
      private(set) var maxConcurrent = 0

      /// Increments the concurrent count.
      func increment() {
        current += 1
        if current > maxConcurrent { maxConcurrent = current }
      }

      /// Decrements the concurrent count.
      func decrement() {
        current -= 1
      }

      /// Resets both current and max counts to zero.
      func reset() {
        current = 0
        maxConcurrent = 0
      }
    }

    /// The shared monitor for tracking concurrent requests.
    private static let monitor = ConcurrentStubMonitor()
    /// The lock guarding stub and delay storage.
    private static let lock = NSLock()
    /// The registered stub data keyed by URL string.
    nonisolated(unsafe) private static var stubs: [String: Data] = [:]
    /// The registered delay for stub responses.
    nonisolated(unsafe) private static var delay: Duration = .zero

    /// Registers stub data for the given URL.
    static func register(data: Data, for url: String) {
      lock.withLock { stubs[url] = data }
    }

    /// Registers a delay for the stub response.
    static func registerDelay(_ delay: Duration) {
      lock.withLock { self.delay = delay }
    }

    /// Synchronous reset that clears the stub registry and delay, and
    /// asynchronously resets the monitor. Callers must await the returned
    /// task to ensure the monitor is fully reset before proceeding.
    static func reset() async {
      lock.withLock { stubs = [:]; delay = .zero }
      await monitor.reset()
    }

    /// Returns the maximum observed concurrency.
    static func maxConcurrency() async -> Int {
      await monitor.maxConcurrent
    }

    /// Returns `true` if the request URL is stubbed.
    override static func canInit(with request: URLRequest) -> Bool {
      let key = request.url?.absoluteString ?? ""
      return lock.withLock { stubs[key] != nil }
    }

    /// Returns the canonical request (identity).
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Starts loading the stubbed response.
    override func startLoading() {
      let key = request.url?.absoluteString ?? ""
      guard let data = Self.lock.withLock({ Self.stubs[key] }) else {
        client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        return
      }

      let storedDelay = Self.lock.withLock { Self.delay }

      Task {
        await Self.monitor.increment()
        if storedDelay > .zero {
          try? await Task.sleep(for: storedDelay)
        }

        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        await Self.monitor.decrement()
      }
    }

    /// Stops loading (no-op for stubs).
    override func stopLoading() {
      // Intentionally empty: stubbed URL protocol has no real load to stop.
    }
  }

  /// Verifies that when `GitHubTransport` is configured with
  /// `maxConcurrentRequests: 2`, launching 4 concurrent `execute()` calls
  /// never allows more than 2 simultaneous `session.data(for:)` operations.
  @Test func maxConcurrentRequestsIsEnforced() async {
    await ConcurrencyTrackedStubProtocol.reset()

    let url = "https://api.github.com/test/concurrency"
    let body = Data("{\"key\":\"value\"}".utf8)
    ConcurrencyTrackedStubProtocol.register(data: body, for: url)
    ConcurrencyTrackedStubProtocol.registerDelay(.milliseconds(100))

    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [ConcurrencyTrackedStubProtocol.self]
    let session = URLSession(configuration: sessionConfig)

    let transport = GitHubTransport(
      session: session,
      tokenProvider: { "test-token" },
      maxConcurrentRequests: 2
    )

    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 4 {
        group.addTask {
          _ = await transport.execute(
            url,
            timeout: 10,
            logTag: "gateTest"
          )
        }
      }
    }

    let maxConc = await ConcurrencyTrackedStubProtocol.maxConcurrency()
    #expect(maxConc == 2, "Maximum concurrent network requests should be 2, got \(maxConc)")
  }
}
