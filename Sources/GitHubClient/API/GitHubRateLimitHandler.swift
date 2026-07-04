// GitHubRateLimitHandler.swift
// GitHubClient

import Foundation

// MARK: - RateLimitSnapshot

/// An atomic snapshot of rate-limit state returned by `RateLimitActorProtocol.snapshot()`.
///
/// Using a nominal struct rather than an anonymous tuple prevents conformers from
/// accidentally dropping named labels (which Swift permits silently for tuples),
/// and keeps the return type extensible (e.g. `Equatable`, `Codable`) without
/// an API break.
public struct RateLimitSnapshot: Sendable, Equatable, Hashable {
    /// Whether the GitHub API is currently rate-limiting this client.
    public let isLimited: Bool
    /// The moment at which the rate-limit window expires, or `nil` if unknown.
    public let resetDate: Date?

    /// Creates a new snapshot with the given rate-limit state.
    ///
    /// - Parameters:
    ///   - isLimited: `true` when the GitHub API is currently rate-limiting this client.
    ///   - resetDate: The moment the rate-limit window expires, or `nil` if unknown.
    public init(isLimited: Bool, resetDate: Date?) {
        self.isLimited = isLimited
        self.resetDate = resetDate
    }
}

// MARK: - RateLimitActorProtocol

/// Injectable abstraction over `RateLimitActor` for deterministic testing.
///
/// `urlSessionExecute` and `urlSessionAPIPaginated` accept any conforming type via
/// a defaulted `rateLimiter` parameter, so production code is unchanged while tests
/// can substitute a `SpyRateLimitActor` without touching the real actor.
///
/// ### resetDate
/// `resetDate` is intentionally absent from this protocol. The production
/// `RateLimitActor` exposes it as `public private(set) var resetDate: Date?`,
/// but callers that hold only a `RateLimitActorProtocol` value should read it
/// through `snapshot()` instead of accessing the property directly. This keeps
/// conformers free to store reset-time however they like without polluting the
/// protocol surface. Do not add `resetDate` to this protocol; add fields to
/// `RateLimitSnapshot` if callers need additional state.
///
/// ### snapshot() and async semantics
/// `snapshot()` is declared non-async to avoid an unnecessary suspension point
/// for intra-actor callers; external callers outside the actor's context must
/// still `await` it — the compiler enforces this.
/// Concretely: all transport functions in this codebase run on the cooperative
/// thread pool and are external callers — they always write `await rateLimiter.snapshot()`.
/// The non-async declaration has no performance benefit for them; it only spares
/// callers *already isolated to the actor* (e.g. actor methods calling `snapshot()`
/// on `self`) from an unnecessary extra hop.
public protocol RateLimitActorProtocol: Actor {
    /// Whether the GitHub API is currently rate-limiting this client.
    var isLimited: Bool { get }
    /// Arms the rate-limit flag and schedules an automatic reset.
    ///
    /// - Parameter resetAt: Absolute seconds since epoch (Unix timestamp),
    ///   matching the `X-RateLimit-Reset` header semantics. A `nil` value means
    ///   the reset time is not known; the conformer should still arm the flag
    ///   and use a reasonable default delay.
    func set(resetAt: TimeInterval?)
    /// Clears the rate-limit flag and cancels any pending reset task.
    func clear()
    /// Clears the rate-limit flag only when the actor is not currently limited.
    ///
    /// This is the correct call after a successful 2xx response in
    /// `urlSessionExecute`. Calling `clear()` unconditionally on every 2xx
    /// introduces a race: a concurrent request that received a genuine 403/429
    /// and armed the actor can have its window erased milliseconds later by
    /// this request returning 200. `clearIfNotLimited()` reads `isLimited` and
    /// calls `clear()` in a single actor hop, so no TOCTOU window exists between
    /// the check and the clear.
    ///
    /// - Note: The intentional clear site — `RunnerStore.fetch()` calling
    ///   `clearGhRateLimit()` at the start of each poll cycle — bypasses this
    ///   guard by design and continues to call `clear()` directly.
    func clearIfNotLimited()
    /// Returns `isLimited` and `resetDate` in a single actor hop.
    ///
    /// Prefer this over reading `isLimited` separately: two individual reads involve
    /// two actor hops with a TOCTOU window between them (P10 — Atomic Snapshot Pattern).
    ///
    /// - Note: Although declared non-async, callers outside this actor's context must
    ///   still `await` this function; the compiler enforces this. See the protocol-level
    ///   `### snapshot() and async semantics` note above for the full explanation.
    ///
    /// - Important: Conformers **must not** reach for `nonisolated(unsafe)` to work
    ///   around the non-async declaration. If a conformer needs async work inside
    ///   `snapshot()`, it should use a lock or actor-safe mechanism instead. All
    ///   current conformers (`RateLimitActor`, `SpyRateLimitActor`) read actor-isolated
    ///   state and have no such need; this constraint preempts a future contributor
    ///   who might wrap an async operation here.
    func snapshot() -> RateLimitSnapshot
}

// MARK: - RateLimitActor

/// Actor-isolated rate-limit state.
///
/// Replaces the old `RateLimitState` struct + `OSAllocatedUnfairLock` + `DispatchWorkItem`
/// pattern. The actor serialises all reads and writes; the reset timer uses a structured
/// `Task` + `Task.sleep(for:)` instead of `DispatchQueue.global().asyncAfter`, so it is
/// natively cancellable and requires no `@unchecked Sendable` escape hatch.
///
/// Pipeline:
///   1. `urlSessionAPIAsync` / `urlSessionAPIPaginated` receive a 403/429.
///   2. They call `rateLimitActor.set(resetAt:)` to arm the rate-limit flag and
///      schedule an automatic clear after the window.
///   3. `ghIsRateLimited` (Bool) and `ghRateLimitSnapshot()` (`RateLimitSnapshot`)
///      expose the current values as `async` accessors backed by the actor.
///   4. `RunnerStore.applyFetchResult` copies both into its own `@MainActor`
///      properties (`isRateLimited`, `rateLimitResetDate`) via a single atomic
///      `snapshot()` call, eliminating the race window between two separate awaits.
///   5. `RunnerViewModel.reload()` mirrors them into `@Published` props.
///   6. `PanelMainView.rateLimitBanner` renders a live countdown using
///      `store.rateLimitResetDate` + the existing 1-second `displayTick`.
public actor RateLimitActor: RateLimitActorProtocol {
    /// Whether the GitHub API is currently rate-limiting this client.
    public private(set) var isLimited = false
    /// The moment at which the rate-limit window expires.
    /// Derived from the clamped delay (not the raw server timestamp) so that the
    /// UI countdown and the internal auto-clear timer always agree.
    /// `nil` when the reset time is unknown.
    public private(set) var resetDate: Date?
    /// Structured task that clears `isLimited` when it fires.
    private var resetTask: Task<Void, Never>?
    /// Incremented on every `set(resetAt:)` call. Captured by each reset task
    /// and compared in `didFire` to ensure a stale task from a cancelled window
    /// cannot clear state that belongs to a newer rate-limit window.
    private var generation = 0

    /// Creates a new `RateLimitActor` instance.
    public init() {}

    /// Arms the rate-limit flag and schedules an automatic reset.
    ///
    /// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response header.
    ///   When non-nil the reset fires precisely at that time (clamped to [5, 7200] s);
    ///   otherwise falls back to 60 minutes from now.
    public func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
        } else {
            delay = 3600
        }
        // Derive resetDate from the clamped delay so the UI countdown matches
        // the actual auto-clear time even when the raw server timestamp falls
        // outside the [5, 7200] clamp range.
        let date = Date().addingTimeInterval(delay)
        log("RateLimitActor › arming: delay=\(Int(delay))s resetDate=\(date)", category: .transport)
        generation &+= 1
        let capturedGeneration = generation
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        // No [weak self] — rateLimitActor is a module-level `let` constant that
        // lives for the entire process lifetime. A weak reference would always
        // resolve to non-nil, making the guard branch unreachable dead code.
        resetTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Cancelled — a newer set(resetAt:) has taken over; do nothing.
                return
            }
            await self.didFire(generation: capturedGeneration, scheduledDelay: delay)
        }
    }

    /// Clears the rate-limit flag and cancels any pending reset task.
    ///
    /// Unconditional: both `isLimited` and `resetDate` are always reset together
    /// to keep them consistent. Clearing only `isLimited` while leaving a stale
    /// `resetDate` would cause the UI to show a countdown for a limit that is no
    /// longer active.
    public func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    /// Clears the rate-limit flag only when the actor is not currently limited.
    ///
    /// Single actor hop — no TOCTOU between the check and the clear.
    /// See `RateLimitActorProtocol.clearIfNotLimited()` for the full rationale.
    public func clearIfNotLimited() {
        guard !isLimited else { return }
        clear()
    }

    /// Returns both `isLimited` and `resetDate` in a single actor hop, guaranteeing consistency.
    public func snapshot() -> RateLimitSnapshot {
        RateLimitSnapshot(isLimited: isLimited, resetDate: resetDate)
    }

    // MARK: Private

    /// Fires when the `Task.sleep` in `set(resetAt:)` completes without cancellation.
    ///
    /// The `generation` check guards against a subtle race: a reset task that has
    /// already exited `Task.sleep` (so `Task.cancel()` can no longer stop it) may
    /// arrive here *after* a newer `set(resetAt:)` has incremented `self.generation`.
    /// Without the check, the stale task would clear `isLimited` and `resetDate` for
    /// the newer, still-active rate-limit window — silently unblocking the app mid-limit.
    ///
    /// Declared `async` even though the body is synchronous — this method is called
    /// with `await` from a non-isolated `Task` closure to cross the actor boundary,
    /// and making it `async` satisfies the Swift 6 compiler warning about `await`
    /// used on a non-async callee.
    private func didFire(generation: Int, scheduledDelay: TimeInterval) async {
        guard generation == self.generation else {
            log("RateLimitActor › stale didFire ignored (gen=\(generation) current=\(self.generation))", category: .transport)
            return
        }
        isLimited = false
        resetDate = nil
        resetTask = nil
        log("RateLimitActor › auto-reset fired after \(Int(scheduledDelay))s", category: .transport)
    }
}

/// The module-wide `RateLimitActor` instance shared by `GitHubResponseDecoder`
/// and `GitHubURLSessionTransport`.
/// Public so both files can call `set(resetAt:)`, `clear()`, and `snapshot()`
/// without crossing module boundaries.
public let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
/// Backed by `RateLimitActor`; must be `await`-ed from async contexts.
///
/// This is a computed async property — SE-0461 executor annotations (`@concurrent`,
/// `nonisolated(nonsending)`) apply to `func` declarations, not `var get async`.
/// As a nonisolated computed async var, it inherits the caller's executor, which is
/// equivalent to `nonisolated(nonsending)` on a func.
///
/// - Note: If you need both `isLimited` and `resetDate` in the same call, prefer
///   `ghRateLimitSnapshot()` to avoid the TOCTOU window between two separate actor hops.
///
/// - Important: If this is ever refactored to a `func`, annotate it `nonisolated(nonsending)`
///   to align with P12 and ensure caller-context executor inheritance is enforced.
public var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag. Called at the start of each poll cycle in `RunnerStore.fetch()`.
///
/// Uses `nonisolated(nonsending)` rather than `@concurrent`: this function has no work
/// before its first suspension, so caller-context inheritance is always correct.
/// A `@concurrent` annotation would add a redundant hop to the cooperative thread pool
/// before the function immediately suspends onto `rateLimitActor`'s executor.
/// `@MainActor` callers release the main thread at the first `await`, so there is no
/// risk of main-thread blocking even without a prior cooperative-pool hop.
/// Clears the GitHub rate-limit flag on the shared rate-limit actor.
nonisolated(nonsending)
public func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns a `RateLimitSnapshot` containing `isLimited` and `resetDate` in a single actor hop.
///
/// Prefer this over reading `ghIsRateLimited` and `rateLimitActor.resetDate` separately:
/// two individual reads involve two actor hops with a TOCTOU window between them.
///
/// Uses `nonisolated(nonsending)` rather than `@concurrent`: this function has no work
/// before its first suspension, so caller-context inheritance is always correct.
/// A `@concurrent` annotation would add a redundant hop to the cooperative thread pool
/// before the function immediately suspends onto `rateLimitActor`'s executor.
/// `@MainActor` callers release the main thread at the first `await`, so there is no
/// risk of main-thread blocking even without a prior cooperative-pool hop.
/// Returns a `RateLimitSnapshot` containing `isLimited` and `resetDate` in a single actor hop.
nonisolated(nonsending)
public func ghRateLimitSnapshot() async -> RateLimitSnapshot {
    await rateLimitActor.snapshot()
}
