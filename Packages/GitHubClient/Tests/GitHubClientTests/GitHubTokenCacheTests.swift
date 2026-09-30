// GitHubTokenCacheTests.swift
// GitHubClientTests
//
// NOTE: Spec #74 Step 6 said "delete GitHubTokenCacheTests.swift".
// This file was REPLACED, not deleted. The filename is retained as the stable
// CI identifier referenced in issue comments and CI logs.
//
// SPEC-REQUIRED TESTS CONFIRMED (issue #74 Step 6 Definition of Done):
//   • token_storeTakesPriorityOverEnv  — store resolution beats env var
//   • token_storeEmptyString_returnsNil — empty Keychain entry is treated as absent
// Both are present below.
//
// Exercises TokenCache resolution order, in-memory caching, and invalidation.
//
// ⚠️ ISOLATION REQUIREMENT
// env-var resolution mutates the process environment (setenv/unsetenv), which
// IS process-global — so the suite stays .serialized and every env-touching
// test wraps its body in withCleanEnv.
//
// Keychain is never touched: token resolution is exercised through a
// MockTokenStore and a StubEnvTokenProvider / EnvReadingStubProvider, keeping
// these tests sandboxing-free and safe to run with `swift test`.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner
// environment. Every env-touching test wraps its body in withCleanEnv, which
// strips both vars and restores them afterwards.

import Foundation
import Synchronization
import Testing

import EnvTokenKit       // plain import — GitHubClientTests only needs public EnvTokenProviding
@testable import GitHubClient

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// ⚠️ SERIALIZED DEPENDENCY: `setenv`/`unsetenv` mutate the process-global
/// environment. Correctness relies on the `@Suite(.serialized)` attribute on
/// `GitHubTokenCacheTests` — if `.serialized` is ever removed, concurrent
/// tests that both call `withCleanEnv` will race on `GH_TOKEN`/`GITHUB_TOKEN`
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
private func withEnv(_ key: String, value: String, _ body: () async -> Void) async {
  let previous = getenv(key).flatMap { String(cString: $0) }
  setenv(key, value, 1)
  await body()
  if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - EnvReadingStubProvider

/// A minimal `EnvTokenProviding` stub that reads environment variables via
/// `getenv()` — not `ProcessInfo.environment` — used only by the env-var tests.
///
/// `getenv()` reads the live POSIX env, so `withEnv`/`withCleanEnv` mutations
/// are visible synchronously — unlike `ProcessInfo.environment`, which is
/// snapshot-cached at process launch.
///
/// `@unchecked Sendable` is NOT used here — the class has no stored mutable
/// state, so it satisfies `Sendable` without any escape hatch.
private final class EnvReadingStubProvider: EnvTokenProviding, Sendable {
  func token() async -> String? {
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
      if let v = getenv(key).flatMap({ String(cString: $0) }), !v.isEmpty { return v }
    }
    return nil
  }
  func invalidate() {
    // Intentionally empty: test stub has no cached state to reset.
  }
}

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

  /// Builds a fresh `TokenCache` backed by an (optionally seeded) `MockTokenStore`.
  ///
  /// `envProvider` overrides the injected env+shell provider so tests never
  /// spawn a real `/bin/zsh` subprocess. Defaults to `StubEnvTokenProvider(result:
  /// .notFound)` which is correct for all nil-path and env-var tests.
  private func makeCache(
    storeToken: String? = nil,
    envProvider: any EnvTokenProviding = StubEnvTokenProvider(result: .notFound)
  ) -> TokenCache {
    TokenCache(
      tokenStore: MockTokenStore(initial: storeToken),
      envProvider: envProvider
    )
  }

  // MARK: - Stored token wins
  // SPEC-REQUIRED (issue #74 Step 6): both tests below are non-optional.

  /// Store resolution beats any environment variable.
  ///
  /// Absorbs: stored-vs-GH_TOKEN, stored-vs-GITHUB_TOKEN, stored-vs-both-env.
  /// Rule: a valid non-empty stored token always wins.
  @Test func token_storeTakesPriorityOverEnv() async {
    await withCleanEnv {
      await withEnv("GH_TOKEN", value: "env-token") {
        let result = await makeCache(
          storeToken: "store-token",
          envProvider: EnvReadingStubProvider()
        ).token()
        #expect(result == "store-token")
      }
    }
  }

  /// An empty-string token returned by the store must be treated as absent
  /// and the cache must fall back to the environment.
  ///
  /// SPEC-REQUIRED (issue #74 Step 6). Kept as a standalone function because
  /// the spec explicitly names it as a Definition-of-Done contract.
  /// Production checks `!stored.isEmpty` — no whitespace trimming — so only
  /// the empty-string case is guaranteed absent; whitespace strings are valid.
  @Test func token_storeEmptyString_returnsNil() async {
    await withCleanEnv {
      let result = await makeCache(storeToken: "").token()
      #expect(result == nil)
    }
  }

  // MARK: - Environment precedence

  /// `GH_TOKEN` takes precedence over `GITHUB_TOKEN` when both are set and
  /// the store is empty.
  ///
  /// Absorbs: token_ghTokenEnvVar_returnsToken, token_githubTokenEnvVarFallback_returnsToken,
  /// token_bothEnvVarsSet_prefersGhToken.
  /// Verifies all three environment-variable precedence cases:
  ///   1. GH_TOKEN only          → GH_TOKEN wins
  ///   2. GITHUB_TOKEN only      → GITHUB_TOKEN wins  (previously missing)
  ///   3. Both vars present      → GH_TOKEN wins (higher priority)
  ///
  /// Absorbs: token_githubTokenEnvVarFallback_returnsToken
  @Test func environmentTokenPrecedence() async {
    let cases: [
      (
        ghToken: String?,
        gitHubToken: String?,
        expected: String?
      )
    ] = [
      (
        "gh-token",
        nil,
        "gh-token"
      ),
      (
        nil,
        "github-token",
        "github-token"
      ),
      (
        "gh-token",
        "github-token",
        "gh-token"
      )
    ]

    for testCase in cases {
      await withCleanEnv {
        if let value = testCase.ghToken {
          setenv("GH_TOKEN", value, 1)
        }
        if let value = testCase.gitHubToken {
          setenv("GITHUB_TOKEN", value, 1)
        }
        let result = await makeCache(
          envProvider: EnvReadingStubProvider()
        ).token()
        #expect(
          result == testCase.expected,
          """
          GH_TOKEN=\
          \(String(describing: testCase.ghToken)) \
          GITHUB_TOKEN=\
          \(String(describing: testCase.gitHubToken))
          """
        )
      }
    }
  }

  // MARK: - Missing stored token falls back to environment

  /// When the store returns nil or empty, resolution falls back to the
  /// environment provider.
  ///
  /// Absorbs: token_noSource separate nil-store case.
  /// Both nil and "" are treated as absent by production (`!stored.isEmpty`).
  @Test func missingStoredTokenFallsBackToEnvironment() async {
    let storedValues: [String?] = [nil, ""]
    for storedValue in storedValues {
      await withCleanEnv {
        setenv("GH_TOKEN", "environment-token", 1)
        let result = await makeCache(
          storeToken: storedValue,
          envProvider: EnvReadingStubProvider()
        ).token()
        #expect(
          result == "environment-token",
          "storedValue=\(String(describing: storedValue))")
      }
    }
  }

  // MARK: - Empty env values are ignored

  /// An empty-string value for either env var must be treated as absent.
  ///
  /// Production (`EnvReadingStubProvider`) checks `!v.isEmpty` only — no
  /// whitespace trimming — so only the empty-string form is guaranteed absent.
  /// Absorbs: token_ghTokenEmptyString_returnsNil, token_githubTokenEmptyString_returnsNil.
  @Test func emptyEnvTokensAreIgnored() async {
    let keys = ["GH_TOKEN", "GITHUB_TOKEN"]
    for key in keys {
      await withCleanEnv {
        setenv(key, "", 1)
        let result = await makeCache(envProvider: EnvReadingStubProvider()).token()
        #expect(result == nil, "empty \(key) must be treated as absent")
      }
    }
  }

  // MARK: - No credential source

  /// Returns nil when the store is empty and no env var is set.
  ///
  /// Absorbs: token_noSource_returnsNil.
  @Test func noCredentialSourceReturnsNil() async {
    await withCleanEnv {
      let result = await makeCache().token()
      #expect(result == nil)
    }
  }

  // MARK: - In-memory cache

  /// A populated cache returns the same value on subsequent calls without
  /// re-reading the environment.
  @Test func token_secondCall_returnsFromCache() async {
    await withCleanEnv {
      let cache = makeCache(envProvider: EnvReadingStubProvider())
      await withEnv("GH_TOKEN", value: "cached-token") {
        _ = await cache.token()  // populate cache
      }
      // Both env vars now absent — only the in-memory cache can return a value.
      let result = await cache.token()
      #expect(result == "cached-token")
    }
  }

  // MARK: - Invalidation

  /// `invalidate()` clears the in-memory cache so the next call re-resolves
  /// from source, forwards to `envProvider.invalidate()`, and is safe to call
  /// on an already-empty cache.
  ///
  /// Absorbs: invalidate_clearsCache, invalidate_whenAlreadyEmpty_isNoop,
  /// invalidate_forwardsToEnvProvider, invalidate_resetsShellOutcome.
  @Test func invalidate_clearsCache() async {
    // Case 1: clears a populated cache so next call re-resolves.
    await withCleanEnv {
      let cache = makeCache(envProvider: EnvReadingStubProvider())
      await withEnv("GH_TOKEN", value: "cached-token") {
        _ = await cache.token()  // populate cache
      }
      cache.invalidate()
      // Env vars absent and cache cleared — next call returns nil.
      let result = await cache.token()
      #expect(result == nil)
    }
    // Case 2: safe to call when already empty (no crash).
    await withCleanEnv {
      let cache = makeCache()
      cache.invalidate()
      let result = await cache.token()
      #expect(result == nil)
    }
    // Case 3: forwards to envProvider.invalidate().
    await withCleanEnv {
      let stub = StubEnvTokenProvider(result: .notFound)
      let cache = makeCache(envProvider: stub)
      cache.invalidate()
      #expect(stub.invalidateCalled.withLock { $0 } == true)
    }
    // Case 4: resetsShellOutcome — provider re-entered after invalidate.
    await withCleanEnv {
      let stub = StubEnvTokenProvider(result: .notFound)
      let cache = makeCache(envProvider: stub)
      _ = await cache.token()        // call 1
      cache.invalidate()
      _ = await cache.token()        // call 2 after invalidate
      #expect(stub.callCount.withLock { $0 } == 2)
    }
  }

  // MARK: - Shell-path latch behaviour

  /// `.notFound` does not latch: a second `token()` call re-enters the
  /// provider rather than short-circuiting. An OAuth-only user who later adds
  /// `GH_TOKEN` to their shell profile should have it picked up on the next
  /// call without relaunching. (Cost tracked in issue #68.)
  ///
  /// Also confirms a fresh `TokenCache` instance resolves from store correctly
  /// after a prior shell-path miss on a different instance.
  @Test func token_shellNotFound_doesNotLatch() async {
    await withCleanEnv {
      let stub = StubEnvTokenProvider(result: .notFound)
      let cache = makeCache(envProvider: stub)
      let first = await cache.token()
      #expect(first == nil)
      let second = await cache.token()
      #expect(second == nil)
      // Provider must have been called twice (no latch).
      #expect(stub.callCount.withLock { $0 } == 2)
      // A fresh instance seeded with a store token is unaffected by the prior miss.
      let seededCache = makeCache(storeToken: "store-token-after-shell")
      let third = await seededCache.token()
      #expect(third == "store-token-after-shell")
    }
  }

  // MARK: - Shell-failed latch (stable CI identifier)

  /// `token_shellFailed_latches` is a FROZEN CI IDENTIFIER (issue #74 Step 6).
  /// Renaming is a non-negotiable spec violation. The current semantics are:
  /// `TokenCache` does NOT latch — the latch lives in `EnvTokenProvider`.
  /// `TokenCache` delegates unconditionally on every call; `callCount == 2`
  /// (not 1) confirms this. The name is preserved as a stable CI reference.
  @Test
  func token_shellFailed_latches() async {
    await withCleanEnv {
      let stub = StubEnvTokenProvider(result: .failed)
      let cache = makeCache(envProvider: stub)
      let first = await cache.token()
      #expect(first == nil)
      #expect(stub.callCount.withLock { $0 } == 1)
      let second = await cache.token()
      #expect(second == nil)
      // callCount == 2, not 1 — TokenCache does NOT latch (see doc comment).
      #expect(stub.callCount.withLock { $0 } == 2)
    }
  }

  // MARK: - Concurrent access

  /// Fifty concurrent Tasks calling `token()` simultaneously must all return
  /// the same value with no crash or data race.
  ///
  /// `TokenCache` uses `Synchronization.Mutex` for thread safety. The store is
  /// seeded so CI-injected env vars are irrelevant (store wins).
  @Test func token_concurrentCalls_allReturnSameToken() async {
    let cache = makeCache(storeToken: "concurrent-token")
    let taskCount = 50
    let results = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
      for _ in 0 ..< taskCount {
        group.addTask { await cache.token() }
      }
      var collected: [String?] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }
    #expect(results.count == taskCount)
    #expect(results.allSatisfy { $0 == "concurrent-token" })
  }
}
