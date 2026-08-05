// TokenCache.swift
// GitHubClient

// public import — not internal import — is required here because TokenCache is a
// public type whose initialisers name EnvTokenProviding (from EnvTokenKit) and
// TokenStore (from OAuthTokenKit) directly in their public parameter lists.
// Swift's access-control rule: a public declaration cannot use a type that is
// imported as internal. Changing either import to `internal import` produces:
//   error: initializer cannot be declared public because its parameter uses an internal type
// The alternative — making TokenCache internal — would remove it from the
// GitHubClient public API, which breaks callers who construct TokenCache in tests.
// `public import` re-exports EnvTokenKit and OAuthTokenKit as part of the
// GitHubClient module surface; that is an intentional, unavoidable consequence
// of keeping TokenCache public with protocol-typed parameters.
//
// See also: GitHubClient.swift — also requires public import OAuthTokenKit
// independently, for its `public let oauthService: any OAuthServiceProtocol`
// property declaration. Both files have genuinely independent compiler reasons;
// neither import is redundant. Removing the import here does not satisfy the
// requirement in GitHubClient.swift, and vice versa.
public import EnvTokenKit
import Foundation
public import OAuthTokenKit
import Synchronization

// MARK: - TokenCache
//
// Resolution chain:
//   1. In-memory cache  (sync, free)
//   2. TokenStore       (sync, Keychain SecItemCopyMatching)
//   3+4. EnvTokenProvider.token() — delegated to injected EnvTokenProviding
//        (ProcessInfo env var for terminal/CI launches; login-shell subprocess
//        for cold Finder/Dock launches). TokenCache has no visibility into
//        how steps 3+4 work — it only calls envProvider.token() and caches
//        the result. See EnvTokenProvider.token() for the full step 3+4 rationale.
//
// TokenCache never names the concrete EnvTokenProvider type — it only
// knows the protocol. The concrete type is constructed and injected
// exclusively by GitHubClient.swift at wiring time.
//
// After a successful resolution the result is written to the in-memory
// cache and all subsequent calls return immediately from step 1.
// invalidate() clears the token cache and calls envProvider.invalidate()
// so the shell outcome latch in EnvTokenProvider is also reset.

/// A token cache that resolves from an injected `TokenStore` and an injected
/// `EnvTokenProviding`, in that order, and caches the result in memory.
/// All cache reads and writes are guarded by a `Mutex` for thread safety.
public final class TokenCache: Sendable {

    /// An injected `TokenStore` used to persist the token to the keychain.
    private let tokenStore: any TokenStore
    /// An optional logger for diagnostic messages.
    /// Optional because diagnostics are never required for correctness — the cache
    /// functions identically with or without a logger. Callers that do not need
    /// diagnostic output pass `nil` (or omit the parameter; it defaults to `nil`).
    private let logger: (any GitHubLogger)?

    /// Injected env+shell token provider.
    ///
    /// `token()` delegates steps 3+4 of the resolution chain to this provider.
    /// `TokenCache` never names the concrete `EnvTokenProvider` type — it only
    /// knows `any EnvTokenProviding`. The concrete type is constructed and
    /// injected exclusively by `GitHubClient.swift`.
    private let envProvider: any EnvTokenProviding

    /// In-memory token cache guarded by a `Mutex`.
    ///
    /// `nil` means "not yet resolved this cache lifetime".
    /// Written by `resolveFromStore()` and the `envProvider` delegation block
    /// in `token()`. Reset to `nil` by `invalidate()`.
    ///
    /// ## Why one Mutex for one field
    ///
    /// > Note: Migrated from PR #75 (EnvTokenKit/OAuthTokenKit extraction).
    /// > The original two-field struct `(token: String?, outcome: ShellResolutionOutcome)`
    /// > required a lock-ordering rationale because both fields were written in different
    /// > call paths (resolveFromStore wrote `token`, EnvTokenProvider wrote `outcome`),
    /// > creating a window where a reader could observe a partial update — a
    /// > deadlock-adjacent ordering issue documented in the original
    /// > `## Why one Mutex for both fields` block.
    /// > That rationale is obsolete: outcome tracking was moved to `EnvTokenProvider`
    /// > in PR #75 when the shell path was extracted into EnvTokenKit. `state` is now
    /// > a single `String?` field with one write path per operation (resolve or
    /// > invalidate). A single-field Mutex has no lock-ordering concern; the original
    /// > deadlock-window argument no longer applies.
    private let state = Mutex<String?>(nil)

    // MARK: - Initialisers

    /// Creates a new `TokenCache`.
    /// - Parameters:
    ///   - tokenStore: The backing store used to load/save/delete the token.
    ///   - envProvider: Resolves steps 3+4 (env var + login shell). In production
    ///     this is `EnvTokenProvider` constructed by `GitHubClient.swift`. In tests
    ///     pass a stub or `NullEnvTokenProvider`. Non-optional: env resolution is a
    ///     load-bearing step in the resolution chain; callers that do not need it
    ///     should pass `NullEnvTokenProvider()` explicitly rather than receiving a
    ///     nil-guarded no-op silently.
    ///   - logger: Optional logger for diagnostic messages. Optional because
    ///     diagnostics are never required for correctness — the cache functions
    ///     identically without one. Defaults to `nil`; existing call sites are
    ///     unaffected.
    public init(
        tokenStore: any TokenStore,
        envProvider: any EnvTokenProviding,
        logger: (any GitHubLogger)? = nil
    ) {
        self.tokenStore = tokenStore
        self.envProvider = envProvider
        self.logger = logger
    }

    /// Creates a `TokenCache` backed by the given store with a `NullEnvTokenProvider`.
    ///
    /// Use this when env-var and login-shell resolution are not needed — for example,
    /// in `GitHubClient`'s test init when no env token path is under test. Pass a
    /// real `EnvTokenProviding` stub to the primary init when env resolution
    /// behaviour is under test.
    ///
    /// NOTE: this init is intentionally `internal`, not `private`. It is called
    /// from `GitHubClient.init(oauthService:transport:tokenCache:)` (the test init)
    /// when `tokenCache` is `nil` — that path lives in `GitHubClient.swift` within
    /// the same module, so `internal` is the correct access level. It is also
    /// reachable from `@testable import GitHubClient` test targets.
    /// Periphery will not flag it as dead code because it is referenced from
    /// `GitHubClient.swift` at the `tokenCache ?? TokenCache(tokenStore: NullTokenStore())`
    /// call site.
    ///
    /// - Parameter tokenStore: The backing token store.
    internal init(tokenStore: any TokenStore) {
        self.tokenStore = tokenStore
        self.envProvider = NullEnvTokenProvider()
        self.logger = nil  // intentional: store-only test path; diagnostics not needed
    }

    // MARK: - Public API

    /// The token that the in-memory cache has already resolved, or `nil` if no
    /// `token()` call has completed yet during this cache lifetime.
    ///
    /// This is a **synchronous, zero-I/O** read — it never spawns a login shell,
    /// reads the Keychain, or checks environment variables. It reflects only what
    /// a prior `token()` call has already written into the in-memory cache.
    ///
    /// ## Typical use
    /// UI code that needs to show an auth-status indicator without going `async`
    /// can read this property after at least one `token()` call has completed
    /// (e.g. from a `.task` modifier that awaits `token()` on appear). Forwarded
    /// by `GitHubClient.cachedToken` as a convenience accessor on the facade.
    public var cachedToken: String? { state.withLock { $0 } }

    /// Resolves and returns the best available token, caching the result in memory.
    ///
    /// Resolution order — first match wins:
    /// 1. **In-memory cache** — zero I/O; populated on first successful resolution.
    /// 2. **`TokenStore`** — one synchronous `SecItemCopyMatching` Keychain read.
    /// 3. **Env var + login shell** — delegated to the injected `EnvTokenProviding`.
    ///    For terminal/CI launches step 3 resolves from `ProcessInfo`; for cold
    ///    Finder/Dock launches step 4 spawns `/bin/zsh -i -l` to source shell
    ///    profile exports.
    ///
    /// A successful resolution at any step writes the result to the in-memory
    /// cache. All subsequent calls return from step 1 until `invalidate()` is
    /// called.
    ///
    /// ## Why `async` when steps 1–3 are synchronous
    /// Steps 1–3 are synchronous and return without ever suspending. The function
    /// is `async` solely because step 4 (`loginShellToken`, inside `EnvTokenProvider`)
    /// is unavoidably async — it uses `@concurrent` + `withTaskGroup` + `waitUntilExit()`.
    /// Swift does not allow a non-async function to call an async one. The cost of the
    /// `async` declaration on the warm path is a single actor-hop check — negligible
    /// compared to any Keychain or subprocess I/O.
    ///
    /// Returns `nil` if no token is available from any source.
    ///
    /// - Warning: Concurrent callers that all miss the in-memory cache simultaneously
    ///   (e.g. on first call at app launch) will each independently walk steps 2–4.
    ///   Steps 1–2 are idempotent (double Keychain read is harmless; `resolveFromStore()`
    ///   writes `state` unconditionally but the Keychain always returns the same value
    ///   for a given entry — see the inline comment on the write site in
    ///   `resolveFromStore()` for the full rationale). Note: a concurrent caller
    ///   racing steps 1–2 cannot overwrite a valid cached value — both callers only
    ///   reach `resolveFromStore()` after `resolveFromCache()` confirmed `state == nil`,
    ///   so the unconditional write can only write the same Keychain value twice,
    ///   which is idempotent. Step 4 is not idempotent:
    ///   each concurrent miss spawns a separate `/bin/zsh` subprocess. The latch is
    ///   not set until `loginShellToken` returns — up to 10 seconds — so the window
    ///   spans the full shell execution time, not merely a scheduling instant. In
    ///   production this is rare because `GitHubClient` is a singleton and callers
    ///   are typically serialised through a single call site. If your call pattern
    ///   can produce high-concurrency first-calls, consider serialising the first
    ///   `token()` call yourself. See `EnvTokenProvider.token()` for the full
    ///   concurrent-spawn rationale.
    ///
    ///   Historical note: an `inFlight` lock was considered and rejected — it added
    ///   complexity for a window that is rare in practice and only occurs during a
    ///   cold Finder/Dock launch where the shell path fires. The thundering-herd
    ///   window is bounded by the shell startup time, not unbounded.
    /// Loads only the OAuth token from `TokenStore`.
    ///
    /// This intentionally bypasses the shared in-memory cache because that cache
    /// may contain a token resolved from the environment path. Reusing it here
    /// could return an environment credential while OAuth mode is selected.
    ///
    /// - Returns: The stored token, or `nil` if the store is empty or absent.
    public func oauthToken() -> String? {
        tokenStore.load()
    }

    /// Resolves the token using the full resolution chain:
    ///
    ///   1. In-memory cache       (sync, free)
    ///   2. TokenStore             (sync, Keychain)
    ///   3. envProvider.token()    (async, env var / login-shell)
    ///
    /// Results from steps 2–4 are written to the in-memory cache so subsequent
    /// calls return from step 1.
    public func token() async -> String? {
        if let cached = resolveFromCache() { return cached }  // Fast path — no I/O, no subprocess
        if let stored = resolveFromStore() { return stored }
        // ⚠️ Concurrent callers each reach envProvider.token() independently —
        // no inFlight guard at this level. See -Warning: above and the full
        // concurrent-spawn rationale in EnvTokenProvider.token().
        if let envToken = await envProvider.token() {
            state.withLock { $0 = envToken }
            return envToken
        }
        return nil
    }

    /// Clears the in-memory token cache and resets the `EnvTokenProvider` shell
    /// outcome latch.
    ///
    /// ## Two-step atomicity window
    /// `invalidate()` performs two operations that cannot be made atomic without
    /// a shared lock between `TokenCache` and `EnvTokenProvider`:
    ///
    /// 1. `state.withLock { $0 = nil }` — clears the in-memory token cache.
    /// 2. `envProvider.invalidate()` — resets `EnvTokenProvider`'s shell latch.
    ///
    /// Between steps 1 and 2, a concurrent `token()` call that misses the cleared
    /// cache but hits the not-yet-reset shell latch could return a stale shell
    /// result. In practice this window is negligible: `RunnerPoller` is a serial
    /// actor and does not call `token()` concurrently with sign-out. If a future
    /// caller introduces concurrent access, either introduce a shared lock or
    /// document the accepted race.
    ///
    /// ## When invalidate() fires
    /// `invalidate()` is called from two paths in production:
    /// - **Sign-out**: `OAuthService.signOut()` → `onTokenDeleted` callback →
    ///   `TokenCache.invalidate()`. The Keychain entry has already been deleted
    ///   at this point; clearing the in-memory cache ensures the next `token()`
    ///   call re-walks the full resolution chain rather than returning a stale value.
    /// - **Sign-in**: `OAuthService.exchangeCode(_:)` → `onTokenSaved` callback →
    ///   `TokenCache.invalidate()`. The new token has just been written to the
    ///   Keychain; invalidating the cache forces the next `token()` call to re-read
    ///   it from the store rather than returning a value from the previous session.
    ///   The two-step atomicity window above therefore applies on sign-in as well
    ///   as sign-out — specifically during the window between a successful
    ///   `exchangeCode` write and the `envProvider.invalidate()` call here.
    public nonisolated func invalidate() {
        state.withLock { $0 = nil }
        envProvider.invalidate()
        // Log fires after both operations — message reflects both: cache nil'd and
        // envProvider latch reset. See ## Two-step atomicity window above.
        logger?.log("TokenCache › invalidate — cache and env-provider latch reset", category: "transport")
        // ## Why calling nonisolated invalidate() from @MainActor is safe under
        // Swift 6 strict concurrency (SWIFT_STRICT_CONCURRENCY=complete)
        // invalidate() is `nonisolated` — Swift permits any isolation domain,
        // including @MainActor, to call a nonisolated function synchronously
        // without a hop or suspension point. The two writes inside
        // (state.withLock and envProvider.invalidate()) are Mutex-protected and
        // nonisolated respectively — neither inherits nor requires @MainActor
        // isolation. The onTokenDeleted closure in GitHubClient.swift captures
        // invalidate() as `() -> Void`, executes on @MainActor (OAuthService is
        // @MainActor), calls nonisolated invalidate() synchronously, and returns.
        // No isolation leak, no deadlock risk. strict concurrency does not flag
        // calling a nonisolated func from an actor — only the reverse requires await.
    }

    // MARK: - Private helpers

    /// Returns the cached token if one is available, otherwise `nil`.
    private func resolveFromCache() -> String? {
        guard let cached = state.withLock({ $0 }) else {
            #if DEBUG
            logger?.log("TokenCache › cache miss", category: "transport")
            #endif
            return nil
        }
        // Cache-hit log is #if DEBUG: invalidate() fires on every sign-in and
        // sign-out, so on an active RunnerPoller cycle (~30 s) this would fire
        // unconditionally in release builds on every warm call after a credential
        // rotation — steady-state release noise with no triage value.
        // (Original code pre-PR #75 also gated the hit log on #if DEBUG.)
        #if DEBUG
        logger?.log("TokenCache › cache hit (len=\(cached.count))", category: "transport")
        #endif
        return cached
    }

    /// Attempts to resolve the token from the injected `TokenStore` (Keychain).
    /// On a hit, writes the result to the in-memory cache and returns it.
    /// On a miss (nil or empty string), returns nil.
    ///
    /// ## Cache-write side effect (not a pure read)
    /// Despite being named `resolveFrom…`, this method writes to `state` on a
    /// store hit. The write is intentional: once a valid token is found in the
    /// Keychain it is promoted to the in-memory cache so all subsequent calls
    /// return from `resolveFromCache()` without touching the Keychain again.
    /// Migrated from the original `resolveFromStore()` doc block; relocated here
    /// from the body comment in the pre-PR #75 implementation.
    ///
    /// ## Why Keychain results are cached in memory
    /// `SecItemCopyMatching` involves a synchronous XPC round-trip to `securityd`.
    /// Caching avoids that round-trip on every `token()` call — especially relevant
    /// for `RunnerPoller` which calls `token()` on every ~30 s poll cycle.
    /// Migrated from the original `## Why Keychain results are cached in memory`
    /// doc block; that block lived on the old `resolveFromStore()` helper.
    ///
    /// ## Why empty strings are rejected
    /// `KeychainTokenStore.load()` can return an empty string if the Keychain
    /// entry was written with an empty value (e.g. a corrupted save). An empty
    /// token is not a usable credential — returning it would cause every
    /// subsequent API call to fail with a 401. Rejecting it here forces the
    /// resolution chain to continue to the env-var / shell path, which is the
    /// correct fallback behaviour.
    ///
    /// The same empty-string rejection is applied in `OAuthService.isAuthenticated`
    /// (PR #75) for the same reason. Both rejections are intentional and symmetric.
    ///
    /// ## Why miss and hit logs are both #if DEBUG
    /// The store-miss path fires on every `token()` call until the cache warms up
    /// and on every call after `invalidate()` when the store is empty (e.g. a
    /// signed-out user). The store-hit path fires once per `invalidate()` cycle —
    /// after sign-in or sign-out, the very next `token()` call always hits the
    /// store (in-memory cache was just cleared). Logging either unconditionally
    /// in release builds produces steady-state noise on every RunnerPoller cycle
    /// (~30 s) with no triage value. See `resolveFromCache()` for the identical
    /// rationale on the cache-hit/miss pair.
    /// Migrated from the original `## Why miss logs are #if DEBUG` doc block;
    /// extended here to cover the hit path consistently.
    private func resolveFromStore() -> String? {
        guard let stored = tokenStore.load(), !stored.isEmpty else {
            #if DEBUG
            logger?.log("TokenCache › store miss", category: "transport")
            #endif
            return nil
        }
        // Store-hit log is #if DEBUG for the same reason as the cache-hit log:
        // fires on every credential-rotation cycle (once per invalidate()) in
        // release builds — steady-state noise with no triage value.
        #if DEBUG
        logger?.log("TokenCache › store hit (len=\(stored.count)), writing to cache", category: "transport")
        #endif
        // Unconditional write is intentional: the Keychain always returns the same
        // value for a given entry, so concurrent callers writing the same token
        // are idempotent. See -Warning: in token() for the full concurrent-caller
        // rationale. The original 'if $0 == nil' guard is not restored here
        // because it would not prevent the invalidate()-race window it appears to
        // guard against — invalidate() sets state to nil BEFORE this write executes,
        // so the nil-check would pass and the stale token would be written back
        // regardless. The guard did prevent one scenario: resolveFromStore() overwriting
        // an envProvider result already written by a concurrent envProvider.token()
        // call on the warm path. That scenario is accepted as idempotent under the
        // current architecture (both sources resolve the same credential). The guard
        // provided no safety benefit on the invalidate() race path specifically —
        // invalidate() sets state to nil before this write executes, so the nil-check
        // would pass and the stale token would be written back regardless. Its removal
        // is intentional on the invalidate() path, with the env-provider-overwrite
        // scenario explicitly accepted — not collateral.
        // The guard prevents a double-write on the warm path only
        // (two concurrent store-hits while the cache is already populated); it does
        // not close the invalidate() + resolveFromStore() interleave. The race
        // window is accepted and documented in ## Two-step atomicity window in
        // invalidate() above.
        //
        // ## Env-provider-overwrite scenario (accepted)
        // The removed guard also prevented one other scenario: a concurrent
        // envProvider.token() write completing between the Keychain read above
        // and this lock call, which this unconditional write would then silently
        // overwrite. This is accepted and idempotent in the current architecture:
        // both the Keychain store and envProvider resolve the same credential
        // (GH_TOKEN / GITHUB_TOKEN / OAuth token), so store-wins-over-env-provider
        // produces the correct value. If the two sources ever diverge (e.g. a
        // credential rotation where the Keychain has the old token and the env
        // has the new one), invalidate() will correct the cache on the next
        // sign-in/sign-out cycle. This scenario is noted here rather than in
        // ## Two-step atomicity window because it is a property of the write
        // site, not of the invalidate() sequencing. No tracking issue is opened:
        // both sources resolve the same credential today and invalidate() corrects
        // any divergence on the next sign-in/sign-out cycle — a TODO would imply
        // this is unresolved, which it is not.
        //
        // Specific scenario addressed: a user with a revoked OAuth Keychain token
        // who has since set GH_TOKEN in their shell profile. resolveFromStore()
        // loading the revoked token and writing it to state is CORRECT —
        // TokenStore (step 2) intentionally wins over envProvider (step 3) in the
        // resolution chain. The revoked token causes 401s, which trigger sign-out,
        // which calls invalidate(), clearing state so the next token() call
        // resolves the valid GH_TOKEN from the shell. Restoring the `if $0 == nil`
        // guard to invert this precedence silently would be the wrong fix.
        state.withLock { $0 = stored }
        return stored
    }
}
