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
/// waiter queue — the permit is **not** leaked. A cancellation handler
/// installed via `withTaskCancellationHandler` ensures that cancellation
/// is observed even after the continuation has been enqueued.
internal actor GitHubRequestGate {

  /// A continuation waiting for a permit, identified by a unique ID for
  /// FIFO ordering and cancellation matching.
  private struct Waiter: Identifiable {
    /// The unique identifier for this waiter, used for cancellation matching.
    let id: UUID
    /// The continuation to resume when a permit is granted (true) or
    /// when the waiter is cancelled (false).
    let continuation: CheckedContinuation<Bool, Never>
  }

  /// The maximum number of concurrent operations allowed.
  private let limit: Int

  /// The number of operations currently executing.
  private var activeCount = 0

  /// Waiters queued in FIFO order, each holding a suspended continuation.
  private var waiters: [Waiter] = []

  /// The number of waiters currently queued.
  /// Exposed for test observation.
  internal var waitingCount: Int {
    waiters.count
  }

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
  /// Checks cancellation before the fast path so that an already-cancelled
  /// caller never acquires a permit. When the gate is full, a
  /// `withTaskCancellationHandler` wraps the checked-continuation suspension
  /// so that cancellation after enqueueing is observed and the waiter is
  /// removed from the queue.
  ///
  /// A post-resumption cancellation check handles the race where
  /// `release()` grants the permit before the cancellation handler reaches
  /// the actor. In that case the newly granted permit is returned to the
  /// pool before throwing.
  private func acquire() async throws {
    try Task.checkCancellation()

    if activeCount < limit {
      activeCount += 1
      return
    }

    let id = UUID()
    let granted = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }

    guard granted else {
      throw CancellationError()
    }

    // The permit was granted — but if the task was also cancelled, release
    // the permit back to the pool so it doesn't leak.
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  /// Removes a waiter from the queue by ID and resumes it with `false`
  /// (cancelled). If the waiter has already been granted a permit (the
  /// release raced ahead of the cancellation handler), this is a no-op
  /// because the waiter is no longer in the queue.
  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
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
