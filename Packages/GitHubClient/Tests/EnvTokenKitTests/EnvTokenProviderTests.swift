// EnvTokenProviderTests.swift
// EnvTokenKitTests
//
// Exercises `EnvTokenProvider` resolution order, shell latch policy, and
// invalidation.
//
// ⚠️ ISOLATION REQUIREMENT
// Tests that exercise the ProcessInfo fast path (env-var resolution) use the
// `envLookup` seam to stub out environment reads entirely, so they never touch
// the live process environment and are immune to cross-suite setenv/unsetenv
// races. `withCleanEnv` is kept as a belt-and-suspenders guard for the small
// number of tests that do need to assert on real env-var pass-through behaviour,
// but the primary isolation mechanism is the injected `envLookup` closure.
//
// No real `/bin/zsh` subprocess is ever spawned. All tests inject a
// `shellResolver` closure that returns a fixed `ShellTokenResult` immediately.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner environment.
// Tests that exercise the shell-fallback path pass `envLookup: { _ in nil }` so
// the live GITHUB_TOKEN never interferes with shell-path assertions.
//
// ## .serialized scope
// Only the ProcessEnvResolution sub-suite uses setenv/unsetenv and requires
// serialisation. All other tests use the envLookup seam and never mutate the
// process environment, so they run concurrently. Serialising the entire outer
// suite would impose unnecessary sequential overhead on CI.

import Foundation
import Synchronization
import Testing

@testable import EnvTokenKit

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// Used only for tests that must assert on real env-var pass-through behaviour
/// (i.e. that `EnvTokenProvider` correctly reads a value set in the process
/// environment). Tests that exercise the shell-fallback path should use the
/// `envLookup` seam instead — see `makeProvider(envLookup:shellResult:)`.
///
/// ⚠️ SERIALIZED DEPENDENCY: `setenv`/`unsetenv` mutate the process-global
/// environment. Correctness relies on the `@Suite(.serialized)` attribute on
/// `ProcessEnvResolution` — if `.serialized` is ever removed from that sub-suite,
/// concurrent tests that both call `withCleanEnv` will race on `GH_TOKEN`/`GITHUB_TOKEN`
/// and produce intermittent flakes.
private func withCleanEnv(_ body: () async -> Void) async {
    let prevGH = getenv("GH_TOKEN").flatMap { String(cString: $0) }
    let prevGitHub = getenv("GITHUB_TOKEN").flatMap { String(cString: $0) }
    unsetenv("GH_TOKEN")
    unsetenv("GITHUB_TOKEN")
    await body()
    if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
    if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets one env var for the duration of body, then restores the previous value.
/// See `withCleanEnv` for the `.serialized` dependency note.
private func withEnv(_ key: String, value: String, _ body: () async -> Void) async {
    let previous = getenv(key).flatMap { String(cString: $0) }
    setenv(key, value, 1)
    await body()
    if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - EnvTokenProviderTests

@Suite("EnvTokenProvider")
struct EnvTokenProviderTests {

    /// Builds a fresh `EnvTokenProvider` with fully injected seams.
    ///
    /// - Parameters:
    ///   - envLookup: Overrides environment variable lookup. Defaults to
    ///     `{ _ in nil }` so tests that exercise the shell-fallback path are
    ///     never affected by the live process environment (e.g. CI-injected
    ///     `GITHUB_TOKEN`). Pass a real lookup or a specific stub when the test
    ///     needs to assert on env-var resolution behaviour.
    ///   - shellResult: The `ShellTokenResult` the resolver will return.
    ///     Defaults to `.notFound` (instant, no I/O).
    private func makeProvider(
        envLookup: (@Sendable (String) -> String?)? = nil,
        shellResult: ShellTokenResult = .notFound
    ) -> EnvTokenProvider {
        EnvTokenProvider(
            shellResolver: { _ in shellResult },
            envLookup: envLookup ?? { _ in nil }
        )
    }

    // MARK: - ProcessEnvResolution (serialized — uses setenv/unsetenv)

    /// Tests that exercise the real process environment via setenv/unsetenv.
    /// Serialised because setenv/unsetenv mutate process-global state.
    /// All other tests in the outer suite use the envLookup seam and run concurrently.
    @Suite("ProcessEnvResolution", .serialized)
    struct ProcessEnvResolution {

        /// Resolves a token from the environment without entering the shell path.
        ///
        /// Uses `withCleanEnv` + `withEnv` to set a real process env var, then
        /// constructs the provider with `envLookup: { key in getenv(key).flatMap { String(cString: $0) } }`
        /// to confirm the end-to-end env-var pass-through path works.
        ///
        /// ## Why getenv() and not ProcessInfo here
        /// `withEnv` sets the env var via `setenv`, which is invisible to
        /// `ProcessInfo.processInfo.environment` (a launch-time snapshot). Using
        /// `getenv()` in the envLookup closure reflects the live process environment
        /// set by `withEnv`, making the test correct on CI where `GITHUB_TOKEN` is
        /// always present at launch and `withCleanEnv`'s `unsetenv` has no effect
        /// on the ProcessInfo snapshot.
        ///
        /// ## How this test validates the shell is not spawned
        /// The injected `shellResolver` increments a counter. If `token()` returns
        /// the env-var value before reaching the shell path, the counter stays 0.
        @Test func envProvider_processInfo_hit() async {
            await withCleanEnv {
                let shellCallCount = Mutex<Int>(0)
                // Use getenv()-based envLookup so setenv mutations from withEnv
                // are visible to the provider. ProcessInfo is a launch-time snapshot
                // and would not see them — see the test doc comment above.
                let provider = EnvTokenProvider(
                    shellResolver: { _ in
                        shellCallCount.withLock { $0 += 1 }
                        return .notFound
                    },
                    envLookup: { key in getenv(key).flatMap { String(cString: $0) } }
                )
                await withEnv("GH_TOKEN", value: "terminal-token") {
                    let result = await provider.token()
                    #expect(result == "terminal-token")
                }
                // getenv() fast path must short-circuit before the shell resolver.
                #expect(shellCallCount.withLock { $0 } == 0)
            }
        }
    }

    // MARK: - token() — ProcessInfo hit (envLookup seam path)

    /// Shell resolver fires when the env lookup returns nil for both vars.
    ///
    /// Uses the `envLookup` seam (`{ _ in nil }`) so this test never touches
    /// the live process environment — immune to CI-injected `GITHUB_TOKEN`
    /// and cross-suite `setenv` races.
    @Test func envProvider_processInfo_miss_shellHit() async {
        // envLookup always returns nil — no dependency on the live process env.
        let provider = makeProvider(
            envLookup: { _ in nil },
            shellResult: .found("shell-token")
        )
        let result = await provider.token()
        #expect(result == "shell-token")
    }

    // MARK: - token() — priority order

    /// `GH_TOKEN` is preferred over `GITHUB_TOKEN` when both are set.
    ///
    /// Uses the `envLookup` seam to inject both values without touching the
    /// live process environment.
    @Test func envProvider_ghToken_preferredOver_githubToken() async {
        let provider = makeProvider(
            envLookup: { key in
                switch key {
                case "GH_TOKEN": return "primary-token"
                case "GITHUB_TOKEN": return "fallback-token"
                default: return nil
                }
            }
        )
        let result = await provider.token()
        #expect(result == "primary-token")
    }

    // MARK: - token() — shell latch: .failed

    /// After the shell returns `.failed`, subsequent `token()` calls must short-circuit
    /// without re-entering the resolver.
    ///
    /// `.failed` latches because retrying a broken or sandbox-blocked shell on every
    /// poll cycle (~30 s) would be a persistent background thread burn with no benefit.
    /// The latch is cleared only by an explicit `invalidate()` call (e.g. sign-out).
    ///
    /// ## Why this asserts on call count, not on the return value
    /// The latch invariant is that the resolver is not called again — not that
    /// `token()` returns nil. The call-count assertion is race-free and sufficient.
    @Test func envProvider_shellFailed_latches() async {
        let resolverCallCount = Mutex<Int>(0)
        // envLookup always nil — forces the shell path on every call.
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .failed
            },
            envLookup: { _ in nil }
        )
        // First call — resolver fires, outcome set to .failed.
        let first = await provider.token()
        #expect(first == nil)
        #expect(resolverCallCount.withLock { $0 } == 1)
        // Second call — .failed latch short-circuits, resolver NOT called again.
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 1, "resolver must not be called again after .failed latch")
    }

    /// After `invalidate()`, the `.failed` latch is cleared so the next `token()`
    /// call re-enters the shell resolver for a fresh attempt.
    @Test func envProvider_invalidate_resetsFailedLatch() async {
        let resolverCallCount = Mutex<Int>(0)
        // envLookup always nil — forces the shell path on every call.
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .failed
            },
            envLookup: { _ in nil }
        )
        // First call — resolver fires, .failed latch set.
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 1)
        // invalidate() resets the latch to .notAttempted.
        provider.invalidate()
        // Second call — latch cleared, resolver fires again.
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 2)
    }

    // MARK: - token() — shell latch: .found

    /// After the shell returns `.found`, subsequent `token()` calls must NOT
    /// re-enter the resolver — the cached value is returned directly.
    ///
    /// This is the regression test for the standalone-use correctness fix:
    /// without the `.found(String)` state write, a second `token()` call on
    /// a standalone `EnvTokenProvider` (not wrapped in `TokenCache`) would
    /// re-spawn `/bin/zsh` on every miss after a prior success.
    ///
    /// `TokenCache`-wired consumers are unaffected (TokenCache short-circuits at
    /// its own cache), but the public `EnvTokenKit` product must be correct
    /// when used directly as documented in the README.
    @Test func envProvider_shellFound_doesNotRespawn() async {
        let resolverCallCount = Mutex<Int>(0)
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .found("shell-token")
            },
            envLookup: { _ in nil }
        )
        // First call — resolver fires, value cached in .found("shell-token").
        let first = await provider.token()
        #expect(first == "shell-token")
        #expect(resolverCallCount.withLock { $0 } == 1)
        // Second call — .found short-circuits, resolver NOT called again.
        let second = await provider.token()
        #expect(second == "shell-token")
        #expect(resolverCallCount.withLock { $0 } == 1, "resolver must not be called again after .found")
    }

    /// After `invalidate()`, the `.found` cache is cleared so the next `token()`
    /// call re-enters the resolver for a fresh shell attempt.
    @Test func envProvider_invalidate_resetsFindLatch() async {
        let resolverCallCount = Mutex<Int>(0)
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .found("shell-token")
            },
            envLookup: { _ in nil }
        )
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 1)
        // invalidate() resets .found back to .notAttempted.
        provider.invalidate()
        // Resolver fires again after reset.
        _ = await provider.token()
        #expect(resolverCallCount.withLock { $0 } == 2)
    }

    // MARK: - token() — shell latch: .notFound

    /// `.notFound` does NOT latch — the resolver is re-entered on the next call.
    ///
    /// An OAuth-only user who later adds `GH_TOKEN` to their shell profile should
    /// have it picked up on the next `token()` call without relaunching.
    @Test func envProvider_shellNotFound_doesNotLatch() async {
        let resolverCallCount = Mutex<Int>(0)
        // envLookup always nil — forces the shell path on every call.
        let provider = EnvTokenProvider(
            shellResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .notFound
            },
            envLookup: { _ in nil }
        )
        _ = await provider.token()
        _ = await provider.token()
        // .notFound does not latch — resolver called on both invocations.
        #expect(resolverCallCount.withLock { $0 } == 2)
    }

    // MARK: - token() — nil path

    /// Returns nil when both env vars are absent and the shell finds nothing.
    @Test func envProvider_noSource_returnsNil() async {
        let result = await makeProvider(shellResult: .notFound).token()
        #expect(result == nil)
    }

    /// Returns nil when `GH_TOKEN` is an empty string.
    @Test func envProvider_ghTokenEmptyString_returnsNil() async {
        let provider = makeProvider(envLookup: { key in key == "GH_TOKEN" ? "" : nil })
        let result = await provider.token()
        #expect(result == nil)
    }

    /// Returns nil when `GITHUB_TOKEN` is an empty string.
    @Test func envProvider_githubTokenEmptyString_returnsNil() async {
        let provider = makeProvider(envLookup: { key in key == "GITHUB_TOKEN" ? "" : nil })
        let result = await provider.token()
        #expect(result == nil)
    }

    // MARK: - invalidate()

    /// Safe to call when no shell attempt has been made — does not crash.
    @Test func envProvider_invalidate_whenNotAttempted_isNoop() async {
        let provider = makeProvider()
        provider.invalidate()  // must not crash
        let result = await provider.token()
        #expect(result == nil)
    }
}
