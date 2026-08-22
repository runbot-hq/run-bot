// EnvTokenProviderTests.swift
// EnvTokenKitTests
//
// Exercises `EnvTokenProvider` resolution order, shell latch policy, and
// invalidation.
//
// All tests inject `envLookup` and `shellResolver` seams — no real `/bin/zsh`
// is ever spawned and the live process environment is never mutated.
//
// GH_TOKEN / GITHUB_TOKEN precedence lives inside `EnvTokenProvider`, so one
// additional precedence test is kept here (see `environmentVariablePrecedence`).
// Store-vs-environment precedence is covered by `GitHubTokenCacheTests`.

import Foundation
import Synchronization
import Testing

@testable import EnvTokenKit

// MARK: - EnvTokenProviderTests

@Suite("EnvTokenProvider")
struct EnvTokenProviderTests {

    /// Builds a fresh `EnvTokenProvider` with fully injected seams.
    ///
    /// - Parameters:
    ///   - envLookup: Stubs environment variable lookup. Defaults to `{ _ in nil }`
    ///     so shell-path tests are immune to CI-injected `GITHUB_TOKEN`.
    ///   - shellResolver: Stubs shell resolution. Defaults to `{ _ in .notFound }`.
    private func makeProvider(
        envLookup: (@Sendable (String) -> String?)? = nil,
        shellResolver: (@Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult)? = nil
    ) -> EnvTokenProvider {
        EnvTokenProvider(
            shellResolver: shellResolver ?? { _ in .notFound },
            envLookup: envLookup ?? { _ in nil }
        )
    }

    // MARK: - Environment hit skips shell

    /// An environment hit returns the token and makes zero shell calls.
    ///
    /// Absorbs: envProvider_processInfo_hit, repeated env-token string variants,
    /// ProcessInfo-before-shell ordering assertions.
    @Test func environmentHitSkipsShell() async {
        let shellCalls = Mutex(0)
        let provider = makeProvider(
            envLookup: { key in key == "GH_TOKEN" ? "environment-token" : nil },
            shellResolver: { _ in
                shellCalls.withLock { $0 += 1 }
                return .found("shell-token")
            }
        )
        let result = await provider.token()
        #expect(result == "environment-token")
        #expect(shellCalls.withLock { $0 } == 0)
    }

    // MARK: - Environment miss uses shell

    /// When no env var is set the shell resolver is invoked and its token returned.
    ///
    /// Absorbs: envProvider_processInfo_miss_shellHit, exact shell-token forwarding.
    @Test func environmentMissUsesShell() async {
        let provider = makeProvider(
            envLookup: { _ in nil },
            shellResolver: { _ in .found("shell-token") }
        )
        #expect(await provider.token() == "shell-token")
    }

    // MARK: - Terminal outcomes are cached

    /// `.found` and `.failed` both latch — the resolver is called exactly once
    /// across repeated `token()` calls.
    ///
    /// Absorbs: envProvider_shellFailed_latches, envProvider_shellFound_doesNotRespawn.
    @Test func foundAndFailedOutcomesAreCached() async {
        let outcomes: [ShellTokenResult] = [.found("shell-token"), .failed]
        for outcome in outcomes {
            let calls = Mutex(0)
            let provider = makeProvider(
                envLookup: { _ in nil },
                shellResolver: { _ in
                    calls.withLock { $0 += 1 }
                    return outcome
                }
            )
            _ = await provider.token()
            _ = await provider.token()
            #expect(
                calls.withLock { $0 } == 1,
                "outcome=\(outcome) must latch after first call"
            )
        }
    }

    // MARK: - .notFound is retried

    /// `.notFound` does NOT latch — the resolver is re-entered on every call.
    ///
    /// Absorbs: envProvider_shellNotFound_doesNotLatch.
    @Test func notFoundOutcomeIsRetried() async {
        let calls = Mutex(0)
        let provider = makeProvider(
            envLookup: { _ in nil },
            shellResolver: { _ in
                calls.withLock { $0 += 1 }
                return .notFound
            }
        )
        #expect(await provider.token() == nil)
        #expect(await provider.token() == nil)
        #expect(calls.withLock { $0 } == 2)
    }

    // MARK: - Invalidation clears cached outcome

    /// `invalidate()` resets a latched `.found` outcome so the next `token()`
    /// call re-enters the resolver.
    ///
    /// Absorbs: envProvider_invalidate_resetsFailedLatch, envProvider_invalidate_resetsFindLatch,
    /// envProvider_invalidate_whenNotAttempted_isNoop, repeated-invalidate no-op.
    @Test func invalidateClearsCachedOutcome() async {
        let calls = Mutex(0)
        let provider = makeProvider(
            envLookup: { _ in nil },
            shellResolver: { _ in
                calls.withLock { $0 += 1 }
                return .found("shell-token")
            }
        )
        _ = await provider.token()
        _ = await provider.token()
        #expect(calls.withLock { $0 } == 1)

        provider.invalidate()

        _ = await provider.token()
        #expect(calls.withLock { $0 } == 2)
    }

    // MARK: - Environment variable precedence

    /// `GH_TOKEN` beats `GITHUB_TOKEN`; `GITHUB_TOKEN` alone is accepted
    /// as fallback. When neither variable exists, resolution falls through
    /// to the shell resolver; the injected `.notFound` result produces nil.
    ///
    /// Precedence is implemented inside `EnvTokenProvider` (envLookup iteration),
    /// so it is covered here rather than in `GitHubTokenCacheTests`.
    ///
    /// Absorbs: envProvider_ghToken_preferredOver_githubToken,
    ///          envProvider_ghTokenEmptyString_returnsNil,
    ///          envProvider_githubTokenEmptyString_returnsNil,
    ///          envProvider_noSource_returnsNil.
    @Test func environmentVariablePrecedence() async {
        let cases: [
            (
                ghToken: String?,
                gitHubToken: String?,
                expected: String?
            )
        ] = [
            ("gh-token",  nil,            "gh-token"),
            (nil,         "github-token", "github-token"),
            ("gh-token",  "github-token", "gh-token"),
            (nil,         nil,             nil)
        ]

        for testCase in cases {
            let shellCalls = Mutex(0)
            let provider = makeProvider(
                envLookup: { key in
                    switch key {
                    case "GH_TOKEN":     return testCase.ghToken
                    case "GITHUB_TOKEN": return testCase.gitHubToken
                    default:             return nil
                    }
                },
                shellResolver: { _ in
                    shellCalls.withLock { $0 += 1 }
                    return .notFound
                }
            )
            let result = await provider.token()
            #expect(
                result == testCase.expected,
                """
                GH_TOKEN=\(String(describing: testCase.ghToken)) \
                GITHUB_TOKEN=\(String(describing: testCase.gitHubToken))
                """
            )
            if testCase.expected != nil {
                #expect(
                    shellCalls.withLock { $0 } == 0,
                    "env hit must not invoke shell"
                )
            }
        }
    }
}
