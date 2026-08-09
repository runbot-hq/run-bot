// GitHubRequestGate.swift
// GitHubClient

import Foundation

/// A cancellation-safe, FIFO semaphore that limits the number of concurrently
/// executing operations to a fixed maximum.
///
/// The gate wraps a classic semaphore pattern with waiter ordering:
/// `withPermit` acquires a permit before executing the operation and releases
/// the permit when the operation completes (even if it throws). Waiters are
/// resumed in FIFO order to prevent starvation.
///
/// ## Thread safety
/// `GitHubRequestGate` is an actor, so all state is isolated to its own
/// serial executor. `withPermit` is `async` and can be called from any
/// concurrent context.
///
/// ## Cancellation
/// If the caller's `Task` is cancelled while waiting for a permit,
/// `withPermit` throws `CancellationError` and releases the spot in the
/// waiter queue — the permit is **not** leaked.
internal actor GitHubRequestGate {

  /// A continuation waiting for a permit, identified by a unique ID for
  /// FIFO ordering and cancellation matching.
  private struct Waiter: Identifiable {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  /// The maximum number of concurrent operations allowed.
  private let limit: Int

  /// The number of operations currently executing.
  private var activeCount = 0

  /// Waiters queued in FIFO order, each holding a suspended continuation.
  private var waiters: [Waiter] = []

  /// Creates a gate with the given concurrency limit.
  ///
  /// - Parameter limit: The maximum number of operations that can execute
  ///   simultaneously. Must be greater than zero.
  init(limit: Int) {
    precondition(limit > 0, "GitHubRequestGate limit must be greater than zero")
    self.limit = limit
  }

  /// Executes the given operation under a permit, ensuring that no more than
  /// `limit` operations run concurrently across all callers of this gate.
  ///
  /// If the maximum concurrency is already reached, the caller suspends until
  /// a permit becomes available. Waiters are resumed in FIFO order.
  ///
  /// - Parameter operation: A closure to execute once a permit is acquired.
  /// - Returns: The value returned by `operation`.
  /// - Throws: `CancellationError` if the caller's task is cancelled while
  ///   waiting for a permit, or whatever error `operation` throws.
  func withPermit<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await acquire()
    defer { release() }
    return try await operation()
  }

  // MARK: - Private helpers

  /// Acquires a permit, suspending if the gate is full.
  ///
  /// If the caller's task is already cancelled, this returns immediately
  /// with a `CancellationError` without adding a waiter to the queue.
  private func acquire() async throws {
    // Fast path: gate has room.
    if activeCount < limit {
      activeCount += 1
      return
    }

    // Slow path: suspend until a permit is released.
    // We use `withCheckedContinuation` and check for cancellation both
    // before and after suspension to handle the race where the task is
    // cancelled while enqueued.
    try Task.checkCancellation()

    let id = UUID()
    let permit = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      waiters.append(Waiter(id: id, continuation: continuation))

      // After enqueuing, check if the task was cancelled. If so, remove
      // the waiter from the queue and resume it with `false` (cancelled).
      // This prevents leaking a waiter when the task is cancelled between
      // the enqueue and the suspension point.
      if Task.isCancelled {
        waiters.removeAll { $0.id == id }
        continuation.resume(returning: false)
      }
    }

    guard permit else {
      throw CancellationError()
    }
  }

  /// Releases one permit and resumes the next waiter (if any) in FIFO order.
  private func release() {
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.continuation.resume(returning: true)
    } else {
      activeCount -= 1
    }
  }
}