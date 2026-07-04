// GitHubTokenCacheTests.swift
// GitHubClientTests
//
// Exercises `TokenCache` resolution order, in-memory caching, and invalidation.
//
// ⚠️ ISOLATION REQUIREMENT
// `TokenCache` is instance-scoped (a fresh instance per test), so there is no
// process-global cache to flush. However, env-var resolution mutates the process
// environment (setenv/unsetenv), which IS process-global — so the suite stays
// .serialized and every test wraps its body in withCleanEnv.
//
// Keychain is never touched: token resolution is exercised through a MockTokenStore
// and environment variables only, keeping these tests sandboxing-free and safe to
// run with `swift test`.
//
// CI note: GitHub Actions always injects GITHUB_TOKEN into the runner environment.
// Every test wraps its body in withCleanEnv, which strips both vars and restores
// them afterwards.

import Foundation
import Testing

@testable import GitHubClient

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
private func withCleanEnv(_ body: () -> Void) {
  let prevGH = ProcessInfo.processInfo.environment["GH_TOKEN"]
  let prevGitHub = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
  unsetenv("GH_TOKEN")
  unsetenv("GITHUB_TOKEN")
  body()
  if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
  if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

/// Sets one env var for the duration of body, then restores the previous value.
private func withEnv(_ key: String, value: String, _ body: () -> Void) {
  let previous = ProcessInfo.processInfo.environment[key]
  setenv(key, value, 1)
  body()
  if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
}

// MARK: - GitHubTokenCacheTests

@Suite("GitHubTokenCache", .serialized)
struct GitHubTokenCacheTests {

  /// Builds a fresh `TokenCache` backed by an (optionally seeded) `MockTokenStore`.
  private func makeCache(storeToken: String? = nil) -> TokenCache {
    TokenCache(tokenStore: MockTokenStore(initial: storeToken))
  }

  // MARK: - token() — nil path

  /// Returns nil when neither env var is set and the store is empty.
  @Test func token_noSource_returnsNil() {
    withCleanEnv {
      #expect(makeCache().token() == nil)
    }
  }

  // MARK: - token() — store priority

  /// Resolves from the `TokenStore` ahead of the environment.
  @Test func token_storeTakesPriorityOverEnv() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "env-token") {
        #expect(makeCache(storeToken: "store-token").token() == "store-token")
      }
    }
  }

  // MARK: - token() — GH_TOKEN

  /// Resolves a token from GH_TOKEN when the store is empty.
  @Test func token_ghTokenEnvVar_returnsToken() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "gh-test-token") {
        #expect(makeCache().token() == "gh-test-token")
      }
    }
  }

  // MARK: - token() — GITHUB_TOKEN fallback

  /// Falls back to GITHUB_TOKEN when GH_TOKEN is absent.
  @Test func token_githubTokenEnvVarFallback_returnsToken() {
    withCleanEnv {
      withEnv("GITHUB_TOKEN", value: "github-test-token") {
        #expect(makeCache().token() == "github-test-token")
      }
    }
  }

  /// Prefers GH_TOKEN over GITHUB_TOKEN when both are set.
  @Test func token_bothEnvVarsSet_prefersGhToken() {
    withCleanEnv {
      withEnv("GH_TOKEN", value: "primary-token") {
        withEnv("GITHUB_TOKEN", value: "fallback-token") {
          #expect(makeCache().token() == "primary-token")
        }
      }
    }
  }

  // MARK: - token() — cache

  /// Returns the cached value on a second call without re-reading the environment.
  @Test func token_secondCall_returnsFromCache() {
    withCleanEnv {
      let cache = makeCache()
      withEnv("GH_TOKEN", value: "cached-token") {
        _ = cache.token()  // populate cache; result discarded intentionally
      }
      // Both env vars now absent — only the in-memory cache can return a value.
      #expect(cache.token() == "cached-token")
    }
  }

  // MARK: - invalidate()

  /// Clears a populated cache so the next call re-resolves from source.
  @Test func invalidate_clearsCache() {
    withCleanEnv {
      let cache = makeCache()
      withEnv("GH_TOKEN", value: "original-token") {
        _ = cache.token()  // populate cache
      }
      cache.invalidate()
      // Cache cleared + both env vars absent + empty store — must return nil.
      #expect(cache.token() == nil)
    }
  }

  /// Safe to call when the cache is already empty — does not crash.
  @Test func invalidate_whenAlreadyEmpty_isNoop() {
    withCleanEnv {
      let cache = makeCache()
      cache.invalidate()  // must not crash on empty cache
      #expect(cache.token() == nil)
    }
  }
}
