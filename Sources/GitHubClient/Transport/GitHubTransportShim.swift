// GitHubTransportShim.swift
// GitHubClient
//
// Provides module-level `ghAPI`, `ghAPIPaginated` symbols
// for RunBotCore consumers (WorkflowActionGroupFetch, RunnerStatusEnricher,
// LogFetcher).
//
// These are thin forwarding stubs backed by configurable transport closures so
// that:
//   • RunBotCore stays independent of the RunBot app target.
//   • Tests can inject a mock transport without touching URLSession.
//   • The app target wires the real GitHubURLSessionTransport at launch.
//
import Foundation
import os

// MARK: - Transport types

/// An async GitHub API fetch returning raw JSON `Data`.
public typealias GHAPITransport = @Sendable (_ endpoint: String) async -> Data?

/// An async raw-bytes fetch for GitHub log endpoints.
/// These endpoints 302-redirect to S3; the transport must follow redirects.
public typealias GHRawTransport = @Sendable (_ endpoint: String) async -> Data?

/// An async paginated GitHub API fetch returning concatenated JSON array `Data`.
///
/// - Parameters:
///   - endpoint: Relative or absolute URL for the first page.
///   - timeout: Per-request timeout forwarded to `URLSession` **for each page**.
///
/// - Warning: The `timeout` value must be forwarded explicitly into the inner
///   call. Swift's type-checker silently accepts a `_` wildcard that drops it:
///   ```swift
///   // ⚠️ WRONG — compiles but silently falls back to the 60-second default:
///   configureGHAPIPaginated { endpoint, _ in
///       await urlSessionAPIPaginated(endpoint)
///   }
///   // ✅ CORRECT — forward timeout explicitly:
///   configureGHAPIPaginated { endpoint, timeout in
///       await urlSessionAPIPaginated(endpoint, timeout: timeout)
///   }
///   ```
///
/// - Note: `apiCallCounter` counts one call per `ghAPIPaginated()` invocation,
///   not one per page fetched. See `APICallCounterRow` tooltip.
public typealias GHAPIPaginatedTransport = @Sendable (_ endpoint: String, _ timeout: TimeInterval) async -> Data?

/// A sync closure that returns the active GitHub personal access token, or `nil`.
public typealias GHTokenProvider = @Sendable () -> String?

// MARK: - TransportBox

/// Thread-safe wrapper around an `OSAllocatedUnfairLock`-guarded closure.
///
/// `OSAllocatedUnfairLock.withLock` accepts a **synchronous** closure only.
/// This is intentional: `os_unfair_lock` must not be held across a suspension
/// point. Transport closures are `async`, so they are *never* called from
/// inside `withLock` — only read out under the lock, then invoked outside it.
///
/// **Reconfigurability is intentional.** `TransportBox` deliberately does not
/// enforce a one-configure-only invariant. `configureGHToken` is called on
/// every test `init()` and in mid-test token-swap scenarios by design.
/// If a one-time-configure invariant is needed for a specific box, enforce it
/// at the call site — do not add a `precondition(isFirstConfigure)` guard
/// inside this type, as that would silently break all tests that reconfigure
/// the transport or token provider mid-suite.
private struct TransportBox<T: Sendable> {
    /// Unfair lock guarding mutable transport state.
    private let lock: OSAllocatedUnfairLock<T>
    /// Creates a `TransportBox` seeded with `initialState`.
    init(initialState: T) { lock = .init(initialState: initialState) }
    /// Replaces the stored transport with `value` under the lock.
    func configure(_ value: T) { lock.withLock { $0 = value } }
    /// Returns the current transport value under the lock.
    func read() -> T { lock.withLock { $0 } }
}

// MARK: - Module-level state

/// Lock-protected box holding the active GitHub JSON transport.
private let transportBox = TransportBox<GHAPITransport>(initialState: { _ in nil })
/// Lock-protected box holding the active raw-bytes transport.
private let rawTransportBox = TransportBox<GHRawTransport>(initialState: { _ in nil })
/// Lock-protected box holding the active paginated transport.
private let paginatedTransportBox = TransportBox<GHAPIPaginatedTransport>(initialState: { _, _ in nil })
/// Lock-protected box holding the active token provider.
private let tokenProviderBox = TransportBox<GHTokenProvider>(initialState: { nil })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub JSON transport. Call once at launch.
public func configureGHAPI(_ transport: @escaping GHAPITransport) {
    transportBox.configure(transport)
}

/// Wire up the raw-bytes transport for log endpoints. Call once at launch.
/// - Parameter rawTransport: Async closure that fetches raw log bytes;
///   must follow 302 redirects, as GitHub log endpoints redirect to S3.
///   Returns `nil` on failure.
public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportBox.configure(rawTransport)
}

/// Wire up the real (or mock) paginated JSON transport. Call once at launch.
///
/// - Parameter transport: Async closure for paginated REST calls.
///   **Always forward `timeout` explicitly** — see `GHAPIPaginatedTransport`
///   for the silent-misconfiguration warning.
public func configureGHAPIPaginated(_ transport: @escaping GHAPIPaginatedTransport) {
    paginatedTransportBox.configure(transport)
}

/// Wire up the token provider. Call once at launch.
///
/// - Parameter provider: Sync closure that returns the current GitHub token,
///   or `nil` when no token is available (e.g. user is signed out).
public func configureGHToken(_ provider: @escaping GHTokenProvider) {
    tokenProviderBox.configure(provider)
}

// MARK: - Module-level symbols

/// Calls the configured GitHub API transport for the given endpoint.
///
/// Increments `apiCallCounter` via a direct `await` **only when the transport
/// returns non-nil data**. Using `await` (not a fire-and-forget `Task`) means
/// task cancellation propagates correctly: a cancelled or timed-out fetch does
/// not increment the counter.
func ghAPI(_ endpoint: String) async -> Data? {
    let transport = transportBox.read()
    let result = await transport(endpoint)
    if result != nil { await apiCallCounter.record() }
    return result
}

// periphery:ignore
/// Calls the configured raw-bytes transport for log endpoints.
/// Returns `nil` on failure or when no transport is configured.
func ghRaw(_ endpoint: String) async -> Data? {
    let transport = rawTransportBox.read()
    return await transport(endpoint)
}

/// Calls the configured paginated JSON transport.
///
/// Increments `apiCallCounter` once per invocation via a direct `await` when
/// the transport returns non-nil data. Cancellation propagates correctly.
///
/// - Important: Annotated `@concurrent`, **not** `nonisolated(nonsending)`.
///   `paginatedTransportBox.read()` acquires an `OSAllocatedUnfairLock`
///   before the first suspension point; `@concurrent` guarantees cooperative
///   thread pool execution at that point. `nonisolated(nonsending)` is only
///   valid for pure pass-throughs — switching to it would silently break this.
@concurrent
public func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    let transport = paginatedTransportBox.read()
    let result = await transport(endpoint, timeout)
    if result != nil { await apiCallCounter.record() }
    return result
}

/// Returns the active GitHub token via the configured provider.
func githubTokenCore() -> String? {
    let provider = tokenProviderBox.read()
    return provider()
}
