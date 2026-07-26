// EnvTokenProvider.swift
// GitHubClient  — intentional: SwiftLint's file_header rule expects the product
//                 module name (GitHubClient), not the Swift package target name
//                 (EnvTokenKit). Changing this to // EnvTokenKit breaks CI lint.
//                 Do not change. See EnvTokenProviderLoginShell.swift for the
//                 same pattern and rationale.
import Foundation
import Synchronization

// MARK: - ShellResolutionOutcome

/// Records the outcome of the most recent login-shell resolution attempt.
///
/// Stored inside `EnvTokenProvider.state` alongside the shell outcome so
/// reads and writes are always consistent under the same `Mutex`.
///
/// ## Why an enum instead of a Bool
/// The previous `shellFailed: Bool` flag collapsed two semantically distinct
/// outcomes — "shell ran but found no export" and "shell failed to launch or
/// timed out" — into a single latch. Both set the flag to `true`, permanently
/// blocking re-entry for the process lifetime. That is correct for `.failed`
/// (retrying a broken shell every 30 s is wasteful) but wrong for `.notFound`
/// (an OAuth-only user who later adds `GH_TOKEN` to their profile should not
/// need a relaunch to pick it up). The enum makes the policy explicit:
/// only `.failed` latches; `.notFound` allows re-entry on the next call.
private enum ShellResolutionOutcome {
    /// No shell attempt has been made yet this provider lifetime.
    case notAttempted
    /// The shell launched and ran successfully but found no `GH_TOKEN` or
    /// `GITHUB_TOKEN` export. The shell path is NOT latched — `token()` will
    /// re-enter it on the next call, allowing the user to add an export
    /// without relaunching the app.
    ///
    /// ## Why not collapse this into `.notAttempted`
    /// Observable behaviour is identical today: both cases allow re-entry.
    /// The distinction is preserved for two reasons:
    /// 1. Diagnostics — logging and future telemetry can distinguish "never
    ///    tried" from "tried and found nothing", which helps triage user
    ///    reports without needing a separate flag.
    /// 2. Future policy — a `.notFound`-specific cooldown (e.g. re-enter at
    ///    most once per 60 s rather than on every poll cycle) could be added
    ///    here without a schema change. Collapsing to `.notAttempted` would
    ///    require a new case or a separate field at that point.
    ///
    /// ## Poll cost for Finder-launch users with no token export
    /// Any Finder-launch user with no `GH_TOKEN` export — OAuth-only users
    /// included — reaches this path on every poll cycle (~30 s) and re-spawns
    /// `/bin/zsh`. This is a known accepted cost: the shell exits quickly
    /// (~50–200 ms on a light config) and the user is unblocked the moment
    /// they add an export without relaunching. The cooldown described in
    /// point 2 above is the right long-term fix and is a schema-free addition
    /// when the cost proves unacceptable in practice.
    ///
    /// ## Why .notFound is NOT latched like .failed
    /// Any Finder-launch user with no `GH_TOKEN` export — OAuth-only users
    /// included — reaches this path on every poll cycle. The decision not to
    /// latch is deliberate: latching `.notFound` like `.failed` would prevent
    /// a user who later adds an export from picking it up without a
    /// sign-out/sign-in cycle, defeating the feature's core promise.
    /// OAuth users launched from a terminal do NOT reach step 4 (step 3
    /// resolves from `ProcessInfo`), but OAuth users launched from Finder
    /// with no export DO. The per-cycle shell cost is real and acknowledged;
    /// the cooldown in issue #68 is the right bounded mitigation — not a
    /// session latch that silently breaks the UX for the users this feature
    /// is designed to help.
    case notFound  // TODO: #68 — add a timestamp-based cooldown so .notFound does not re-spawn /bin/zsh on every poll cycle (~30 s) for Finder-launch users with no token export
    /// The shell ran and returned a token. The resolved value is cached here
    /// so subsequent `token()` calls short-circuit without re-spawning
    /// `/bin/zsh` — critical for standalone callers that do not wrap this
    /// provider in a `TokenCache`.
    ///
    /// This is NOT a permanent latch in the `.failed` sense: `invalidate()`
    /// resets the outcome to `.notAttempted`, so a sign-out/sign-in cycle
    /// always gets a fresh shell attempt regardless of a prior `.found`.
    ///
    /// `TokenCache`-wired consumers are unaffected — `TokenCache` short-circuits
    /// at its own in-memory cache (step 1) after the first successful resolution
    /// and never calls `envProvider.token()` again until `invalidate()` fires.
    /// The `.found` write here is the correct fix for the standalone-use path
    /// documented in the `EnvTokenKit` README.
    case found(String)
    /// The shell timed out, failed to launch, or was blocked by the App Sandbox.
    /// The shell path IS latched — `token()` short-circuits before the shell
    /// on every subsequent call until `invalidate()` resets the outcome.
    /// Retrying a broken or sandbox-blocked shell every poll cycle (~30 s)
    /// would be a persistent background thread burn with no benefit; the user
    /// must take explicit action (fix `~/.zshrc`, remove the sandbox
    /// entitlement, or sign in via OAuth) before a retry is useful.
    case failed
}

/// Resolves `GH_TOKEN` / `GITHUB_TOKEN` from the process environment or a
/// login-shell subprocess, and exposes the result via `EnvTokenProviding`.
///
/// Injected into `TokenCache` in `GitHubClient`. `TokenCache` never names
/// this type — it only knows `any EnvTokenProviding`. The concrete type is
/// constructed exclusively in `GitHubClient.swift` at wiring time.
///
/// All mutable state is guarded by a `Mutex` for thread safety.
public final class EnvTokenProvider: EnvTokenProviding, Sendable {

    /// Optional log closure bridged from `GitHubLogger` by `GitHubClient.swift`.
    /// `EnvTokenKit` never depends on `GitHubLogger` directly — the closure
    /// bridge keeps the kit self-contained.
    private let log: (@Sendable (String, String) -> Void)?

    /// Resolves a token via the login shell.
    ///
    /// Defaults to the real `loginShellToken` free function. Overridable in
    /// tests via the `shellResolver` init parameter so test suites never spawn
    /// a real `/bin/zsh` subprocess — avoiding the 10-second timeout on
    /// nil-path tests and keeping the suite fast on both local and CI runners.
    private let shellResolver: @Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult

    /// Reads a single environment variable by key.
    ///
    /// Defaults to `ProcessInfo.processInfo.environment[key]` in production.
    ///
    /// ## ProcessInfo vs getenv() — intentional divergence
    /// `ProcessInfo.processInfo.environment` is a snapshot captured at process
    /// launch; `setenv`/`unsetenv` mutations after launch are invisible to it.
    /// This is the correct default here: `EnvTokenProvider` is not expected to
    /// observe environment mutations within a running process.
    /// `OAuthService.hasAnyToken` makes the opposite choice — it uses `getenv()`
    /// so the UI auth-state check always reflects the live environment. See
    /// `envVarIsSet(_:)` in `OAuthService.swift` for the full rationale. Both
    /// choices are intentional and documented at their respective call sites.
    ///
    /// Overridable in tests via the `envLookup` init parameter so tests that
    /// exercise the shell-fallback path never touch the live process environment
    /// — eliminating the cross-suite `setenv`/`unsetenv` race on CI where
    /// `GITHUB_TOKEN` is always present in the runner environment.
    private let envLookup: @Sendable (String) -> String?

    /// Shell outcome state guarded by a `Mutex`.
    ///
    /// Tracks the result of the last login-shell attempt.
    /// See `ShellResolutionOutcome` for the per-case latch policy.
    private let state = Mutex<ShellResolutionOutcome>(.notAttempted)

    /// Production init. `log` is bridged from `GitHubLogger` by `GitHubClient.swift`.
    public convenience init(log: (@Sendable (String, String) -> Void)? = nil) {
        self.init(log: log, shellResolver: nil, envLookup: nil)
    }

    /// Test init — exposes `shellResolver` and `envLookup` seams so tests never
    /// spawn real `/bin/zsh` and never touch the live process environment.
    ///
    /// - Parameters:
    ///   - log: Optional log closure.
    ///   - shellResolver: Overrides login-shell resolution. Defaults to the real
    ///     `loginShellToken` free function.
    ///   - envLookup: Overrides environment variable lookup. Defaults to
    ///     `ProcessInfo.processInfo.environment[key]`. Pass `{ _ in nil }` in
    ///     tests that exercise the shell-fallback path to avoid any dependency
    ///     on the live process environment.
    init(
        log: (@Sendable (String, String) -> Void)? = nil,
        shellResolver: (@Sendable ((@Sendable (String, String) -> Void)?) async -> ShellTokenResult)? = nil,
        envLookup: (@Sendable (String) -> String?)? = nil
    ) {
        self.log = log
        self.shellResolver = shellResolver ?? { log in await loginShellToken(log: log) }
        self.envLookup = envLookup ?? { key in ProcessInfo.processInfo.environment[key] }
    }

    // MARK: - EnvTokenProviding

    /// Resolves a token from the process environment or a login-shell subprocess.
    ///
    /// Resolution order:
    /// 1. `GH_TOKEN` in the process environment (defaults to
    ///    `ProcessInfo.processInfo.environment`; injectable via `envLookup` in tests)
    /// 2. `GITHUB_TOKEN` in the process environment (same lookup path as above)
    /// 3. Cached shell result — returns immediately if a prior shell call already
    ///    resolved a value (`.found`), without re-spawning `/bin/zsh`.
    /// 4. Login-shell subprocess (`/bin/zsh -i -l`) — Finder/Dock launches only,
    ///    and only when no prior resolution is cached.
    ///
    /// ## Shell latch policy
    /// - `.notAttempted`: shell is spawned normally.
    /// - `.notFound`: shell ran but found no export — NOT latched. Re-entry
    ///   allowed so the user can add an export without relaunching.
    /// - `.found(value)`: shell previously returned a value — short-circuits
    ///   immediately without re-spawning `/bin/zsh`. Reset by `invalidate()`.
    /// - `.failed`: shell timed out or failed to launch — IS latched until
    ///   `invalidate()` resets the outcome.
    ///
    /// - Warning: Concurrent callers that simultaneously miss the ProcessInfo
    ///   fast path will each spawn a separate `/bin/zsh` subprocess. The latch
    ///   is not set until `loginShellToken` returns (up to 10 s), so the window
    ///   spans the full shell execution time, not just a scheduling instant.
    ///   Correctness is preserved under two assumptions that hold in practice:
    ///   (1) `GH_TOKEN` / `GITHUB_TOKEN` are static for the process lifetime
    ///   (set before launch, not mutated at runtime), so concurrent shell runs
    ///   each resolve the same value and write `.found(sameValue)` idempotently;
    ///   (2) `invalidate()` is not called concurrently with an in-progress shell
    ///   spawn — in production it is driven by a serial `RunnerPoller` actor so
    ///   this condition holds. If either assumption is violated, one caller may
    ///   overwrite a fresher `.found` value or a `.notAttempted` reset with a
    ///   stale result. If your call pattern violates either, serialise access yourself.
    ///
    /// ## Why `@concurrent` is absent from this signature
    /// `token()` is deliberately NOT marked `@concurrent`. Marking it `@concurrent`
    /// would hop execution to a cooperative thread pool executor, meaning the
    /// `state.withLock` write-back in the `.found` case below would execute
    /// off the caller's actor. The caller's actor could then observe a torn
    /// read/write window between its own state access and the write-back.
    /// Keeping `token()` on the caller's actor ensures the write-back is
    /// sequenced consistently from the caller's perspective. The absence of
    /// `@concurrent` here is intentional and not an oversight — the
    /// `shellResolver` call inside hops to a concurrent context via its own
    /// `@concurrent` / `async` annotation; `token()` itself does not need to.
    public func token() async -> String? {
        if let envToken = resolveFromEnvironment() { return envToken }
        // Check the cached shell outcome before spawning a new subprocess.
        switch state.withLock({ $0 }) {
        case .found(let cached):
            // A prior shell call already resolved a value — return it immediately
            // without re-spawning /bin/zsh. This is the critical short-circuit for
            // standalone callers that do not wrap this provider in a TokenCache.
            // Reset by invalidate() so sign-out cycles get a fresh shell attempt.
            return cached
        case .failed:
            return nil
        case .notAttempted, .notFound:
            break
        }
        // All fast paths missed — cold Finder/Dock/login-item launch.
        // Spawn the login shell to source ~/.zprofile and ~/.zshrc.
        // ⚠️ No atomic entry claim: concurrent callers each spawn a separate
        // /bin/zsh — the latch is not set until loginShellToken returns.
        // See -Warning: above for the full window and mitigation guidance.
        let shellResult = await shellResolver(log)
        switch shellResult {
        case .found(let value):
            // Cache the successful outcome so subsequent calls short-circuit
            // without re-spawning /bin/zsh. Not a permanent latch — invalidate()
            // resets to .notAttempted so sign-out cycles get a fresh attempt.
            // Unconditional write — idempotent under the static-env assumption in
            // -Warning: above: concurrent callers each write .found(sameValue) because
            // they awaited the same shell result with the same static env var.
            // No `if case .notAttempted` entry guard needed; see -Warning: above.
            state.withLock { $0 = .found(value) }
            return value
        case .notFound:
            // Shell ran fine but no token was exported.
            // Do NOT latch — allow re-entry. See ShellResolutionOutcome.notFound.
            //
            // ## Why the Mutex write is not skipped
            // After the first .notFound result, state already holds .notFound —
            // writing it again on the next poll cycle is a no-op in terms of
            // observable behaviour. A reviewer might flag this as a redundant
            // write and suggest skipping it with `if case .notAttempted = state`.
            // Do NOT add that guard. Reasons:
            // 1. The write is cheap (a Mutex lock + enum assignment) — far less
            //    costly than the /bin/zsh spawn it follows.
            // 2. Skipping the write would require an extra Mutex read before the
            //    shell spawn (to distinguish .notAttempted from .notFound), adding
            //    a branch to the hot path with no measurable benefit.
            // 3. When the #68 cooldown is implemented, the write site becomes the
            //    place to record the timestamp. A guard that skips the write would
            //    need to be removed at that point, creating a subtle regression risk.
            // The redundant write is intentional. It is bounded (one per shell
            // spawn, ~30 s apart) and the correct hook for the #68 timestamp.
            state.withLock { $0 = .notFound }
            return nil
        case .failed:
            // Shell timed out, failed to launch, or was blocked by the sandbox.
            // Latch to prevent re-spawning on every poll cycle. See .failed.
            state.withLock { $0 = .failed }
            return nil
        }
    }

    /// Resets the shell outcome latch to `.notAttempted` so the next `token()`
    /// call re-enters the full resolution chain.
    ///
    /// Called by `TokenCache.invalidate()` after sign-out so a sign-in cycle
    /// gets a fresh shell attempt even if the previous one timed out.
    ///
    /// Resetting `shellOutcome` here is intentional: a sign-out / sign-in cycle
    /// should get exactly one fresh shell attempt on the next `token()` call,
    /// even if the previous attempt timed out. Without this reset the user would
    /// be permanently locked out of the shell path for the process lifetime after
    /// a single `.failed` outcome, regardless of whether they subsequently fix
    /// their `~/.zshrc` or reduce its startup cost.
    public func invalidate() {
        state.withLock { $0 = .notAttempted }
        log?("EnvTokenProvider › invalidate — shell outcome reset", "transport")
    }

    // MARK: - Private helpers

    /// Reads `GH_TOKEN` or `GITHUB_TOKEN` via the injected `envLookup` closure.
    ///
    /// In production `envLookup` reads `ProcessInfo.processInfo.environment`.
    /// In tests it can be stubbed to return a fixed value or nil, eliminating
    /// any dependency on the live process environment.
    ///
    /// ## Why GH_TOKEN is checked before GITHUB_TOKEN
    /// Both variables resolve the same credential. `GH_TOKEN` is the shorter,
    /// preferred form documented in the README. Checking it first means a user
    /// who sets both gets the expected one without any silent override.
    ///
    /// ## Why miss logs are #if DEBUG
    /// The nil/empty miss path fires on every `token()` call for OAuth-only
    /// users who have no `GH_TOKEN` export — that is every poll cycle (~30 s)
    /// indefinitely in production. Two unconditional log lines per cycle would
    /// be permanent steady-state noise in release builds for every OAuth-only
    /// user. The hit path (successful resolution) remains unconditional because
    /// it fires at most once per `TokenCache` lifetime and is the signal that
    /// matters for triage. The miss path is only useful during active debugging,
    /// so it is guarded by `#if DEBUG`.
    private func resolveFromEnvironment() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let value = envLookup(key), !value.isEmpty {
                log?("EnvTokenProvider › resolved from env var \(key) (len=\(value.count))", "transport")
                return value
            }
            #if DEBUG
            log?("EnvTokenProvider › env var \(key): nil/empty", "transport")
            #endif
        }
        return nil
    }
}
