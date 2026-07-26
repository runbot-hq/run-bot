// StubEnvTokenProvider.swift
// GitHubClientTests/TestSupport
import Foundation
import Synchronization

@testable import GitHubClient
import EnvTokenKit  // required: conformance declaration 'StubEnvTokenProvider: EnvTokenProviding' must
                    // name the protocol through a direct import, not via GitHubClient's re-export.

// MARK: - StubEnvResult

/// Local result vocabulary for `StubEnvTokenProvider`.
///
/// Mirrors the three outcomes of `EnvTokenProvider`'s internal resolution
/// (found / notFound / failed) without importing any `EnvTokenKit` internal
/// type. This breaks the fragile `@testable import EnvTokenKit` coupling that
/// would make `GitHubClientTests` sensitive to `EnvTokenKit` internals — if
/// any internal result type is ever renamed or made private, only
/// `EnvTokenKitTests` (which owns that vocabulary) breaks, not this target.
///
/// NOTE: `.failed` and `.notFound` are behaviourally identical from
/// `TokenCache`'s perspective — both cause `token()` to return `nil` and
/// neither triggers a latch inside `TokenCache` (the latch lives in
/// `EnvTokenProvider`). Do NOT collapse them into a single case. The
/// distinction is intentional:
///   • `.notFound` — simulates the normal "no token available" path.
///   • `.failed` — simulates a shell/env error path. Tests use `callCount`
///     to assert that `TokenCache` re-delegates on every call even under
///     the error scenario (expected callCount = N for an N-call test).
///     Collapsing the cases would remove the ability to express this intent.
enum StubEnvResult {
    case found(String)
    case notFound
    case failed
}

// MARK: - StubEnvTokenProvider

/// A test double for `EnvTokenProviding` that returns a fixed `StubEnvResult`
/// and never spawns a real `/bin/zsh` subprocess.
///
/// ## Why a stub rather than keeping shellResolver:
/// `TokenCache` no longer owns the shell path — it delegates steps 3+4 entirely
/// to the injected `any EnvTokenProviding`. Tests that need to control the
/// env/shell path inject a `StubEnvTokenProvider` via `TokenCache(tokenStore:, envProvider:)`.
///
/// ## callCount
/// The `callCount` Mutex lets latch tests assert exactly how many times `token()`
/// was called — matching what the old `counter` locals in `token_shellFailed_latches`
/// did with the direct `shellResolver:` closure.
///
/// ## invalidateCalled
/// Tracks whether `invalidate()` was forwarded by `TokenCache.invalidate()`, so
/// tests that verify the reset path can assert the delegation happened.
final class StubEnvTokenProvider: EnvTokenProviding, Sendable {

    /// The result returned by `token()` on every call.
    private let result: StubEnvResult

    /// Number of times `token()` has been called.
    let callCount = Mutex<Int>(0)

    /// Whether `invalidate()` has been called at least once.
    let invalidateCalled = Mutex<Bool>(false)

    /// - Parameter result: The `StubEnvResult` to simulate.
    ///   - `.found(value)`: `token()` returns `value`.
    ///   - `.notFound`: `token()` returns `nil` without latching.
    ///   - `.failed`: `token()` returns `nil`. Latch enforcement lives inside
    ///     `EnvTokenProvider` — `TokenCache` does NOT latch. Use `callCount`
    ///     to verify delegation on every call (expected count = 2 for a two-call test).
    init(result: StubEnvResult = .notFound) {
        self.result = result
    }

    func token() async -> String? {
        callCount.withLock { $0 += 1 }
        switch result {
        case .found(let value): return value
        case .notFound:         return nil
        // .failed returns nil here just like .notFound — this is intentional.
        // The distinction exists to let tests assert *why* nil was returned:
        // .notFound = no token found (normal path), .failed = shell/env error
        // (error path). TokenCache treats both identically (no latch), but
        // tests use callCount to verify delegation still occurs on every call
        // under the .failed scenario. Do not collapse these two cases.
        case .failed:           return nil
        }
    }

    func invalidate() {
        invalidateCalled.withLock { $0 = true }
    }
}
