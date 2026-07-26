// EnvTokenProviderLoginShell.swift
// GitHubClient  — intentional: SwiftLint's file_header rule expects the product
//                 module name (GitHubClient), not the Swift package target name
//                 (EnvTokenKit). Changing this to // EnvTokenKit breaks CI lint.
//                 Do not change.
import Foundation
import Synchronization

// MARK: - Login shell resolution (@concurrent for blocking I/O)

/// The result of a login-shell token resolution attempt.
///
/// Returned by `loginShellToken` and consumed by `token()` to set
/// `ShellResolutionOutcome` in the provider state.
///
/// ## Access level: internal
/// `ShellTokenResult` is `internal` because it is part of the `shellResolver`
/// closure seam on `EnvTokenProvider`'s internal test init. It is reachable
/// from `EnvTokenKitTests` via `@testable import EnvTokenKit`.
///
/// If you are consuming `EnvTokenKit` from an external test target that cannot
/// use `@testable` (e.g. a separate package that lists `EnvTokenKit` as a
/// dependency), you cannot construct a `shellResolver` stub — use the public
/// `EnvTokenProvider.init(log:)` convenience init instead, which defaults to
/// the real login-shell path. For full shell-seam control from an external
/// target, copy `StubShellResolver` from `EnvTokenKitTests/TestSupport/` or
/// file a request to promote `ShellTokenResult` to `public`.
enum ShellTokenResult {
    /// The shell ran and found an exported token.
    case found(String)
    /// The shell ran successfully but found no `GH_TOKEN` / `GITHUB_TOKEN` export.
    case notFound
    /// The shell timed out, failed to launch, or was blocked by the App Sandbox.
    case failed
}

/// The sentinel prefix written by the shell before the token value.
/// Long enough that it cannot appear in `.zshrc` output by coincidence.
/// The subprocess arm extracts only the sentinel-prefixed line, discarding
/// all other stdout — immune to any `.zshrc` noise regardless of content.
///
/// Sentinel collision: a token that itself begins with `GH_TOKEN_VALUE:` would
/// have those leading characters stripped, producing a truncated invalid token.
/// This is not a practical risk — all real GitHub PAT formats (`ghp_`,
/// `github_pat_`, `ghs_`, etc.) are defined by GitHub and none begin with this
/// sentinel. If GitHub ever issues a token format that starts with `GH_TOKEN_VALUE:`
/// this assumption must be revisited.
///
/// printf argument safety: the token value is passed as the `%s` argument, not
/// as part of the format string. Any `%` characters in the token value are not
/// interpreted as format specifiers — only `%` in the format string itself
/// would be. Real GitHub PAT formats do not contain `%`, but this is safe
/// regardless of token content.
///
/// Shell quoting: the `printf` command is wrapped in single quotes. If a token
/// value ever contained a `'` character it would break the shell quoting and
/// produce unexpected output. Current GitHub PAT formats (`ghp_`, `github_pat_`,
/// `ghs_`) use only alphanumeric + `_` characters — no `'` is possible today.
/// If that ever changes, this quoting must be revisited.
private let shellTokenSentinel = "GH_TOKEN_VALUE:"

/// Spawns `/bin/zsh -i -l` to recover `GH_TOKEN` or `GITHUB_TOKEN` from the
/// user's shell profile and returns a typed `ShellTokenResult`.
///
/// ## @concurrent — blocking I/O off the main actor
/// `waitUntilExit()` blocks a thread. `@concurrent` keeps that off any
/// actor's serial executor. Free function rather than a `nonisolated` instance
/// method because `@concurrent` requires a non-isolated declaration context —
/// which a `nonisolated` method on a `final class` does technically satisfy —
/// but a free function makes the isolation boundary explicit at the call site
/// and avoids capturing `self` across a concurrency boundary, keeping the
/// `Sendable` conformance of `EnvTokenProvider` clean without auditing which
/// `self` members are accessed.
///
/// ## -i flag (intentional)
/// Sources `~/.zshrc`, where most users export `GH_TOKEN`. Without it,
/// `-l` alone only sources `~/.zprofile` and misses tokens set in `.zshrc`.
/// Stdout noise from interactive mode is neutralised by the sentinel strategy.
///
/// ## -i flag and interactive zsh startup latency
/// Interactive mode triggers full zsh initialisation: PS1 setup, `compinit`,
/// and any user hooks (oh-my-zsh, nvm, rvm, pyenv, etc.). On a minimally
/// configured machine this is ~50–200ms. On a heavily configured machine with
/// a cold `compinit` cache, startup can reach 1–3 seconds. The 10-second
/// timeout budget includes process-launch time — on a slow machine where
/// `process.run()` itself takes a moment, the effective shell-resolution
/// window is shorter than 10 s. The timeout is generous for the common case
/// but may feel tight for users with expensive `~/.zshrc` setups. Correctness
/// is unaffected — the sentinel strategy isolates the token from all stdout
/// noise regardless of init duration. If the timeout proves too tight in
/// practice, increase it or add a user-facing note in the README.
///
/// ## Shell choice: /bin/zsh (not $SHELL)
/// Guaranteed on every supported macOS since Catalina. `$SHELL` would require
/// per-shell flag negotiation with no benefit for the macOS-only target.
///
/// ## Timeout arm uses do/catch (not try?)
/// `try? Task.sleep` silently swallows `CancellationError`. When the subprocess
/// arm succeeds in under 10s, `group.cancelAll()` cancels the timeout task.
/// `try?` would eat the error and fall through to the log + terminate() call,
/// emitting a false "timed out" log on every successful resolution.
/// `do { try … } catch { return nil }` exits cleanly on cancellation.
/// Note: the `.failed` returned by the cancelled timeout arm is consumed by
/// structured concurrency's implicit group teardown — it is never collected
/// by a second `group.next()` call, and has no effect on the caller.
///
/// ## group.next() first-result semantics — timeout-path token discard (intentional)
/// `group.next()` returns whichever arm completes first. If the subprocess arm
/// finishes before 10 s it wins and the token is returned. If the timeout arm
/// fires first, `group.next()` returns `.failed` and `cancelAll()` is called —
/// any token the shell was about to produce is intentionally discarded.
/// This is a deliberate fail-safe: returning `.failed` after a timeout is safer
/// than returning a token whose resolution time exceeded the budget. The caller
/// (`token()`) sets `shellOutcome = .failed` on this result, preventing re-spawns.
///
/// ## Pipe buffer deadlock prevention (withCheckedContinuation drain)
/// `waitUntilExit()` blocks until the child exits. If the child writes enough
/// data to fill the pipe kernel buffer (~64 KB on macOS) before exiting —
/// plausible with a verbose `.zshrc` running neofetch, nvm, or oh-my-zsh —
/// the child blocks on the write side waiting for the buffer to drain while
/// this code blocks on `waitUntilExit()` waiting for the child to exit:
/// deadlock. The fix is to drain the pipe concurrently on a `DispatchQueue`
/// worker thread using `withCheckedContinuation`, suspending the async task
/// until the drain completes. `waitUntilExit()` is then called after
/// `await drainPipe(outPipe)` returns, by which point all stdout has been
/// read and the child has already exited naturally.
///
/// ## Why withCheckedContinuation instead of DispatchSemaphore
/// Swift 6 strict concurrency (SE-0296) marks `DispatchSemaphore.wait()` as
/// unavailable from async contexts — including inside `@concurrent` task
/// closures, which are still typed `async`. `withCheckedContinuation` is the
/// correct Swift 6 idiom for bridging a blocking call that must run off the
/// async executor. It also eliminates the `#SendableClosureCaptures` warning
/// from a captured `var` because data flows through the continuation's resume
/// value rather than a mutated capture.
///
/// ## Why stderr is not drained
/// `standardError` is redirected to `FileHandle.nullDevice` — the OS kernel
/// sink, not a `Pipe`. There is no pipe buffer; bytes are discarded immediately.
/// `readDataToEndOfFile()` is never called on stderr, so there is no second
/// drain to coordinate and no second deadlock window. If stderr is ever changed
/// to a `Pipe`, a matching `drainPipe()` call before `waitUntilExit()` becomes
/// required.
///
/// ## On the timeout path: does drainPipe hang?
/// If the timeout arm fires and calls `terminate()` while the drain is still
/// running, `terminate()` sends SIGTERM to the shell, which causes the shell
/// to exit and close the write end of the pipe. A closed write end causes
/// `readDataToEndOfFile()` to return immediately with whatever was buffered,
/// the continuation is resumed, and `await drainPipe(outPipe)` returns
/// promptly. No hang.
///
/// ## Thread leak on the timeout path (known, bounded)
/// After `group.next()` + `group.cancelAll()`, this function returns before
/// both leaked resources have necessarily resolved:
/// 1. The `DispatchQueue` thread running `drainPipe` — unblocks promptly
///    once SIGTERM causes the shell to exit and close the pipe write end.
/// 2. The cooperative pool thread running the subprocess arm — holds
///    `waitUntilExit()` until zsh actually exits after SIGTERM.
/// Both threads are held until the shell exits. For this `zsh -c printf` use
/// case zsh exits in under a second after SIGTERM, so the window is brief.
/// If `loginShellToken` is ever adapted for longer-running subprocesses,
/// consider adding a SIGKILL after a grace period — SIGTERM is not guaranteed
/// to be honoured promptly by shells with custom `trap … TERM` handlers or
/// by zsh in certain zle (line-editor) states.
///
/// ## App Sandbox (not currently applicable — known cliff)
/// `Process` is unavailable in a sandboxed Mac app. If the app is ever
/// sandboxed, `process.run()` will throw a permission error, `loginShellToken`
/// returns `.failed`, and `token()` sets `shellOutcome = .failed` — the user
/// gets no token with no obvious diagnostic. The entire `loginShellToken` path
/// must be removed before enabling the sandbox entitlement.
///
/// ## Thundering-herd on concurrent callers
/// `loginShellToken` has no guard against concurrent callers — two `token()`
/// calls that simultaneously miss all fast paths will each spawn a separate
/// `/bin/zsh` process. Both will ultimately write the same value to the cache
/// (the `if $0.token == nil` Mutex guard in `token()` prevents a double-write),
/// so correctness is preserved. In practice this cannot happen: `RunnerPoller`
/// is a single serial actor and is the only caller of `token()` in the app, so
/// at most one cold-launch shell is ever spawned. A future public API consumer
/// that calls `token()` concurrently from multiple tasks should be aware of this.
///
/// - Returns: A `ShellTokenResult` discriminating between a found token,
///   a healthy shell with no export, and a launch/timeout failure.
@concurrent
func loginShellToken(log: (@Sendable (String, String) -> Void)?) async -> ShellTokenResult {
    let box = ProcessBox()
    return await withTaskGroup(of: ShellTokenResult.self) { group in
        // Subprocess arm — spawn, drain stdout, wait, read.
        group.addTask {
            // Cheap early-exit if the task group was cancelled before this arm
            // was scheduled (e.g. loginShellToken itself was cancelled before
            // any work started). This is a best-effort check only — it does not
            // protect against cancellation racing with process.run() below.
            // That window is intentionally unguarded: if the task is cancelled
            // after run() succeeds, the timeout arm's terminate() is the kill
            // path, or the shell runs to fast natural completion. Correctness
            // is unaffected either way.
            guard !Task.isCancelled else { return .failed }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-i", "-l", "-c",
                "printf '\(shellTokenSentinel)%s\\n' \"${GH_TOKEN:-${GITHUB_TOKEN:-}}\""
            ]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            // /dev/null is a kernel sink, not a Pipe — no buffer to fill, no drain needed.
            // See "Why stderr is not drained" in the loginShellToken doc comment above.
            process.standardError = FileHandle.nullDevice
            // Redirect stdin to /dev/null. /bin/zsh -i (interactive mode) reads
            // from stdin by default. For a Finder/Dock launch the inherited stdin
            // is already the null device, but redirecting explicitly prevents a
            // hang if this path is ever reached from a terminal-context caller
            // where stdin would otherwise be the user's terminal.
            // /dev/null is accessible inside the App Sandbox, so this is safe
            // regardless of sandbox state (though Process.run() itself would
            // throw before this matters in a sandboxed binary).
            process.standardInput = FileHandle.nullDevice
            // Store the process in the box before calling run() so the timeout arm
            // can always reach it via terminate(). The `launched` sentinel below
            // clears the box on a run() throw so the timeout arm sees nil and
            // skips terminate() cleanly.
            box.state.withLock { $0 = process }
            // Explicit sentinel rather than checking processIdentifier == 0:
            // Process.processIdentifier is documented as 0 before launch, but
            // Apple's API makes no contract about its value after a run() throw.
            // `launched` is set only after run() succeeds, so its meaning is
            // unambiguous regardless of any future Process API change.
            var launched = false
            defer { if !launched { box.state.withLock { $0 = nil } } }
            // ⚠️ App Sandbox: Process.run() throws a permission error in a sandboxed
            // app. loginShellToken must be removed before enabling the sandbox
            // entitlement. See the loginShellToken doc comment for details.
            do {
                try process.run()
                launched = true
            } catch {
                log?(
                    "EnvTokenProvider › login shell failed to launch: \(error). "
                    + "Check that /bin/zsh is present and executable.",
                    "transport"
                )
                // The defer above clears box.state so the timeout arm skips
                // terminate() cleanly. Caller sets shellOutcome = .failed on .failed return.
                return .failed
            }
            // Drain stdout via withCheckedContinuation BEFORE calling waitUntilExit().
            // If the pipe kernel buffer (~64 KB on macOS) fills before the child exits,
            // calling waitUntilExit() first would deadlock: child blocks on write(),
            // this task blocks on waitUntilExit(). drainPipe() runs readDataToEndOfFile()
            // on a DispatchQueue worker thread and suspends this async task until the
            // drain completes; by the time we reach waitUntilExit() the pipe is fully
            // drained and the child has exited naturally. See doc comment for details.
            let data = await drainPipe(outPipe)
            // waitUntilExit() does not honour Swift task cancellation.
            // The timeout arm calls box.state.withLock { $0 }?.terminate() as the kill path.
            // The drain above ensures this never deadlocks on a pipe-full condition.
            // Note: on the common fast path the shell has already exited by the time
            // drainPipe() returns (readDataToEndOfFile() unblocks when the write end
            // closes, which happens on shell exit). waitUntilExit() on an already-
            // exited process checks isRunning internally and returns immediately —
            // it is not a hang risk even when called after the child is gone.
            process.waitUntilExit()
            // terminationStatus is intentionally not checked. The shell's exit code is
            // irrelevant to token resolution — what matters is whether the sentinel line
            // appeared in stdout. A shell that exits non-zero (e.g. a .zshrc hook that
            // calls `exit 1`) but printed the sentinel line before exiting still gives
            // us a valid token. Checking the exit code and discarding a found token on
            // non-zero status would silently break resolution for those users.
            guard let raw = String(data: data, encoding: .utf8) else { return .failed }
            let value = raw
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix(shellTokenSentinel) else { return nil }
                    return String(line.dropFirst(shellTokenSentinel.count))
                }
                .first ?? ""  // .first: if .zshrc somehow produces multiple sentinel-prefixed
                              // lines (not possible with the single printf command, but
                              // defensive), take the first. An empty result is handled
                              // below as .notFound.
            // Trim whitespace and carriage returns. Some terminal emulators write
            // CRLF line endings; a trailing \r would produce Bearer <token>\r and
            // every API call would return 401 silently.
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // The shell launched and ran successfully, but found no GH_TOKEN
                // or GITHUB_TOKEN export in ~/.zprofile / ~/.zshrc.
                // This is expected for OAuth-only users — not an error.
                // Return .notFound (not .failed) so the caller does NOT latch the
                // shell path: the user can add an export and have it picked up
                // on the next token() call without relaunching the app.
                log?(
                    "EnvTokenProvider › login shell ran successfully but found no token export. "
                    + "This is normal for OAuth-only users. "
                    + "To use a PAT on Finder/Dock launches, export GH_TOKEN or GITHUB_TOKEN "
                    + "in ~/.zprofile or ~/.zshrc.",
                    "transport"
                )
                return .notFound
            }
            #if DEBUG
            log?("EnvTokenProvider › resolved from login shell (len=\(trimmed.count))", "transport")
            #endif
            return .found(trimmed)
        }
        // Timeout arm — kill the shell after 10s.
        // do/catch exits cleanly on cancellation without logging. See doc comment.
        group.addTask {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                // CancellationError from group.cancelAll() when the subprocess arm won.
                // The .failed return value here is consumed by structured concurrency's
                // implicit group teardown — it is never collected and has no effect.
                return .failed
            }
            log?(
                "EnvTokenProvider › login shell timed out after 10 s — terminating. "
                + "If your ~/.zshrc has expensive startup hooks (oh-my-zsh, nvm, compinit, etc.), "
                + "consider moving the GH_TOKEN export to ~/.zprofile instead, "
                + "which is sourced without -i and avoids the full interactive init.",
                "transport"
            )
            box.state.withLock { $0 }?.terminate()
            return .failed
        }
        // group.next() returns the result of whichever arm completes first.
        // If the timeout arm wins, the shell's token (if any) is intentionally
        // discarded — fail-safe over fail-open. See doc comment for full rationale.
        // The caller (token()) sets shellOutcome = .failed on a .failed result.
        //
        // ShellTokenResult?? → ShellTokenResult: group.next() returns nil only when
        // all tasks have already been collected, which is structurally unreachable
        // here — two tasks were added and only one group.next() call is made.
        // ?? .failed rather than group.next()! for two reasons:
        // 1. Force-unwrap would crash if the structural assumption were ever violated
        //    (e.g. a future refactor that removes one of the addTask calls). .failed
        //    is the safe, correct fallback — it treats an unexpected nil as a failure,
        //    which triggers the .failed latch and prevents silent re-spawns.
        // 2. It satisfies the type system without a fatalError that would show up in
        //    crash logs as a false positive on a path that should never be reached.
        let result: ShellTokenResult = await group.next() ?? .failed
        group.cancelAll()
        return result
    }
}

/// Drains `pipe` by calling `readDataToEndOfFile()` on a `DispatchQueue` worker
/// thread and bridging the result back to the async caller via `withCheckedContinuation`.
///
/// `readDataToEndOfFile()` blocks until the write end of the pipe is closed (i.e.
/// the child process exits or is terminated). Running it on a `DispatchQueue` thread
/// keeps the blocking I/O off the Swift concurrency cooperative pool.
///
/// `qos: .utility` signals background I/O intent — this is not interactive work.
/// Under memory pressure, `.utility` is deprioritised less aggressively than the
/// default global queue while still yielding to interactive QoS work.
///
/// On the timeout path: `terminate()` sends SIGTERM to the shell, which closes
/// the pipe write end, causing `readDataToEndOfFile()` to return immediately with
/// whatever was buffered. The continuation is resumed promptly — no hang.
///
/// ## Never-resume bound (withCheckedContinuation safety)
/// `withCheckedContinuation` requires the continuation to be resumed exactly once.
/// The only call site is inside `DispatchQueue.global(qos:).async` — a simple
/// fire-and-forget closure with no error path, no early return, and no throw.
/// `readDataToEndOfFile()` is an Objective-C method that raises an `NSException`
/// on a closed or invalid file handle. However, `outPipe` is created immediately
/// before `process.run()` in the subprocess arm — it is a freshly allocated
/// `Pipe()` whose read end is never closed before `drainPipe()` is called. The
/// write end is closed only when the child process exits or `terminate()` is
/// called, both of which cause `readDataToEndOfFile()` to return normally rather
/// than raise. There is therefore no reachable code path in which the continuation
/// goes unresolved. If this function is ever adapted to drain a pipe whose file
/// handle may already be closed at call time, wrapping `readDataToEndOfFile()`
/// in an Objective-C `@try/@catch` shim (or switching to the `AsyncBytes` API)
/// becomes required to preserve the resume-exactly-once invariant.
private func drainPipe(_ pipe: Pipe) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: data)
        }
    }
}

/// Shares the `Process` reference between the subprocess arm and the timeout arm
/// behind a `Mutex` for formally safe cross-task access.
///
/// `Process` is not `Sendable` so it cannot be captured directly across task
/// boundaries. Wrapping it in a `Mutex<Process?>` gives us a properly `Sendable`
/// container with no `@unchecked` annotation required — all reads and writes
/// are synchronised by the lock.
///
/// A `defer` in the subprocess arm clears the box if `run()` throws (guarded by
/// the explicit `launched` sentinel), so the timeout arm sees `nil` and skips
/// `terminate()` on a process that never launched.
///
/// ## Process dealloc does not terminate
/// When `withTaskGroup` returns and `box` is released, ARC deallocates this
/// instance. `Process` deallocation does NOT send SIGTERM to the subprocess —
/// an orphaned shell will continue running until it exits naturally or is killed
/// by another means. For the `zsh -c printf` use case the shell exits in under
/// a second after SIGTERM (sent by the timeout arm) or after the command
/// completes (subprocess arm). Do NOT rely on `Process` dealloc as a cleanup
/// mechanism in any future adaptation of this pattern.
private final class ProcessBox: Sendable {
    /// The spawned `/bin/zsh` process, or `nil` if not yet started or launch failed.
    /// Guarded by a `Mutex` for safe cross-task read/write without `@unchecked Sendable`.
    let state = Mutex<Process?>(nil)
}
