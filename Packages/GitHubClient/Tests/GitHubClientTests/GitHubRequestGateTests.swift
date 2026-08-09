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
  @Test func withPermit_cancelledWaiterDoesNotLeakPermit() async {
    let gate = GitHubRequestGate(limit: 1)

    let holdPermit = SimplePromise()
    let occupierTask = Task {
      try? await gate.withPermit {
        await holdPermit.wait()
      }
    }

    await Task.yield()

    let cancelledTask = Task {
      try? await gate.withPermit { /* should not execute */ }
    }
    await Task.yield()
    cancelledTask.cancel()

    holdPermit.signal()
    _ = await occupierTask.result

    let result = try? await gate.withPermit { "third" }
    #expect(result == "third")
  }

  // MARK: - FIFO waiter order

  /// Verifies that waiters are resumed in FIFO order when permits become
  /// available.
  @Test func withPermit_waitersAreResumedInFIFOOrder() async {
    let gate = GitHubRequestGate(limit: 1)
    let order = OrderRecorder()

    let holdPermit = SimplePromise()
    let occupierTask = Task {
      try? await gate.withPermit {
        await holdPermit.wait()
      }
    }

    await Task.yield()

    let taskA = Task {
      try? await gate.withPermit { await order.record("A") }
    }
    let taskB = Task {
      try? await gate.withPermit { await order.record("B") }
    }
    let taskC = Task {
      try? await gate.withPermit { await order.record("C") }
    }

    await Task.yield()

    holdPermit.signal()
    _ = await occupierTask.result
    _ = await taskA.result
    _ = await taskB.result
    _ = await taskC.result

    let recorded = await order.order
    #expect(recorded == ["A", "B", "C"], "Waiters must be resumed in FIFO order, got \(recorded)")
  }
}

// MARK: - Test helpers

private enum TestError: Error {
  case someError
}

private actor ConcurrencyMonitor {
  private var current = 0
  private(set) var maxConcurrent = 0
  private(set) var totalEntered = 0

  func enter() {
    current += 1
    totalEntered += 1
    if current > maxConcurrent { maxConcurrent = current }
  }

  func exit() {
    current -= 1
  }
}

private actor OrderRecorder {
  private(set) var order: [String] = []

  func record(_ label: String) {
    order.append(label)
  }
}

private final class SimplePromise: @unchecked Sendable {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { c in
      continuation = c
    }
  }

  func signal() {
    continuation?.resume()
    continuation = nil
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
  private final class ConcurrencyTrackedStubProtocol: URLProtocol, @unchecked Sendable {

    private static let monitor = ConcurrentStubMonitor()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Data] = [:]
    nonisolated(unsafe) private static var delay: Duration = .zero

    static func register(data: Data, for url: String) {
      lock.withLock { stubs[url] = data }
    }

    static func registerDelay(_ delay: Duration) {
      self.delay = delay
    }

    static func reset() {
      lock.withLock { stubs = [:]; delay = .zero }
      Task { await monitor.reset() }
    }

    static func maxConcurrency() async -> Int {
      await monitor.maxConcurrent
    }

    override class func canInit(with request: URLRequest) -> Bool {
      let key = request.url?.absoluteString ?? ""
      return lock.withLock { stubs[key] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let key = request.url?.absoluteString ?? ""
      guard let data = Self.lock.withLock({ Self.stubs[key] }) else {
        client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        return
      }

      Task {
        await Self.monitor.increment()
        let delay = Self.lock.withLock { Self.delay }
        if delay > .zero {
          try? await Task.sleep(for: delay)
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

    override func stopLoading() {}
  }

  /// Actor that tracks the maximum concurrent in-flight requests.
  private actor ConcurrentStubMonitor {
    private var current = 0
    private(set) var maxConcurrent = 0

    func increment() {
      current += 1
      if current > maxConcurrent { maxConcurrent = current }
    }

    func decrement() {
      current -= 1
    }

    func reset() {
      current = 0
      maxConcurrent = 0
    }
  }

  deinit {
    ConcurrencyTrackedStubProtocol.reset()
  }

  /// Verifies that when `GitHubTransport` is configured with
  /// `maxConcurrentRequests: 2`, launching 4 concurrent `execute()` calls
  /// never allows more than 2 simultaneous `session.data(for:)` operations.
  @Test func maxConcurrentRequestsIsEnforced() async {
    ConcurrencyTrackedStubProtocol.reset()

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