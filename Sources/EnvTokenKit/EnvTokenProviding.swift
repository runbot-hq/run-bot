// EnvTokenProviding.swift
// GitHubClient  — intentional: SwiftLint's file_header rule expects the product
//                 module name (GitHubClient), not the Swift package target name
//                 (EnvTokenKit). Changing this to // EnvTokenKit breaks CI lint.
//                 Do not change. See EnvTokenProviderLoginShell.swift for the
//                 same pattern and rationale.

// MARK: - EnvTokenProviding
//
// Abstraction over the env-var + login-shell token resolution path.
// The protocol lives permanently in EnvTokenKit; TokenCache in GitHubClient
// depends on it via the EnvTokenKit product dependency in Package.swift.

/// Abstraction over a token provider that resolves `GH_TOKEN` / `GITHUB_TOKEN`
/// from the process environment or a login-shell subprocess.
///
/// ## Why a protocol and not a closure?
/// A single `() async -> String?` closure would be sufficient for the
/// `token()` direction, but `invalidate()` needs a paired reset signal so
/// `TokenCache` can propagate sign-in / sign-out events down to the shell
/// outcome latch in `EnvTokenProvider`. Two closures would work but require
/// more bookkeeping at the call site and make the relationship between the
/// two operations less explicit. A named protocol groups them, documents their
/// contract, and gives test authors a single type to stub.
///
/// ## Sendable requirement
/// `TokenCache` is `Sendable` (it wraps all mutable state in a `Mutex`).
/// Any `EnvTokenProviding` stored inside it must therefore also be `Sendable`.
/// `EnvTokenProvider` satisfies this via its own `Mutex`-guarded state.
/// Test stubs satisfy it by using only immutable (`let`) stored properties
/// or actor-isolated state.
///
/// ## Adopted by
/// - `EnvTokenProvider` (production, lives in `EnvTokenKit`)
/// - Test stubs in `EnvTokenKitTests` and `GitHubClientTests`
public protocol EnvTokenProviding: Sendable {

    /// Resolves a token from the process environment or login shell.
    ///
    /// Resolution order:
    /// 1. `GH_TOKEN` via the injectable `envLookup` closure (production default:
    ///    `ProcessInfo.processInfo.environment`; overridable in tests)
    /// 2. `GITHUB_TOKEN` via the same `envLookup` closure
    /// 3. Login-shell subprocess (`/bin/zsh -i -l`) for Finder/Dock launches
    ///    where the process environment does not inherit shell exports.
    ///
    /// Note: `OAuthService.hasAnyToken` reads the same env vars via `getenv()`
    /// rather than `ProcessInfo` — an intentional divergence for live-environment
    /// accuracy in UI auth-state checks. That is OAuthService's policy, not this
    /// protocol's. See `envVarIsSet(_:)` in `OAuthService.swift` for the rationale.
    ///
    /// Returns `nil` if no token is available from any source, or if the
    /// login-shell path has latched to `.failed` after a prior timeout or
    /// launch error. See `ShellResolutionOutcome` in `EnvTokenProvider` for
    /// the full latch policy.
    ///
    /// ## Caching behaviour
    /// `EnvTokenProvider` caches a **shell** result internally, but does **not**
    /// cache env-var hits. These two paths have different caching semantics:
    ///
    /// - **Env-var hit** (`GH_TOKEN` / `GITHUB_TOKEN` via `envLookup`):
    ///   Not cached at the provider level. `ProcessInfo.processInfo.environment`
    ///   is an immutable snapshot captured at process launch — there is no mutable
    ///   state to write into, and re-reading it on every call is effectively free.
    ///   If you consume `EnvTokenProvider` standalone (not wrapped in `TokenCache`),
    ///   every `token()` call that hits an env var re-reads `ProcessInfo`. This is
    ///   intentional and correct. `TokenCache` caches the resolved value at its own
    ///   layer, so in the production wiring an env-var hit is only re-read once per
    ///   `TokenCache` lifetime (between `invalidate()` calls).
    ///
    /// - **Shell hit** (login-shell subprocess result):
    ///   Cached inside `EnvTokenProvider` via the `ShellResolutionOutcome.found`
    ///   latch under a `Mutex`. Subsequent calls short-circuit at that latch and
    ///   return the cached value without re-spawning `/bin/zsh`. Calling
    ///   `invalidate()` clears the latch so the next `token()` call re-runs the
    ///   full resolution chain.
    ///
    /// **Summary for standalone consumers:** if you use `EnvTokenProvider` directly
    /// (outside of `TokenCache`), only the shell path is cached automatically.
    /// Call `invalidate()` after a sign-out or credential rotation to force
    /// re-resolution of both paths.
    ///
    /// - Warning: Concurrent callers can each spawn a separate `/bin/zsh`
    ///   subprocess during the window before the first shell result is cached
    ///   (up to 10 s). The concrete `EnvTokenProvider` is safe today because
    ///   `RunnerPoller` calls it serially, but any conformer or caller that
    ///   invokes `token()` concurrently from multiple tasks should be aware of
    ///   this window. See `EnvTokenProvider.token()` for the full rationale.
    ///
    /// - Note: Conformers that allow `.notFound` re-entry (as `EnvTokenProvider` does)
    ///   must be called from a serialised context. `EnvTokenProvider` is designed for
    ///   use via a serial `RunnerPoller` actor. Concurrent callers are not supported at
    ///   the protocol level — see `EnvTokenProvider.token()` `-Warning:` block for the
    ///   full concurrent-spawn rationale and accepted limitations.
    ///
    /// - Note: The caching behaviour described in `EnvTokenProvider`'s doc comment
    ///   (env-var hits are not cached at the provider level; shell hits are cached via
    ///   `ShellResolutionOutcome.found`) is specific to the production conformer, not a
    ///   protocol contract. A conformer may cache env-var hits. The protocol only
    ///   requires that `token()` return the best available token and that `invalidate()`
    ///   reset any internal state so the next `token()` call re-resolves from scratch.
    func token() async -> String?

    /// Resets all internal state so the next `token()` call re-runs the full
    /// resolution chain from scratch.
    ///
    /// Called by `TokenCache` after every successful sign-in and sign-out so
    /// that a credential change is reflected immediately on the next `token()`
    /// call rather than served from a stale latch.
    ///
    /// `nonisolated` is intentional: `TokenCache.invalidate()` is itself
    /// `nonisolated` and must call this synchronously without an `await`.
    /// Conforming types on a `@MainActor` class must explicitly add
    /// `nonisolated` to their implementation; omitting it produces a silent
    /// actor hop and breaks the synchronous call chain at runtime.
    nonisolated func invalidate()
}
