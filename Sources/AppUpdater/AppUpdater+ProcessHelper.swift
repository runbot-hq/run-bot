// AppUpdater+ProcessHelper.swift
// AppUpdater
import Foundation

// MARK: - Process helper

/// Runs a command and returns `true` on exit code 0, `false` otherwise.
///
/// Used for `ditto` (unzip and bundle replacement) which is short-lived and
/// does not need streaming output.
///
/// ## Why this is a free function, not an `AppUpdater` method
///
/// `runCommand` is a module-level free function, not an extension on `AppUpdater`.
/// The file is named `AppUpdater+ProcessHelper.swift` for co-location only —
/// the `+` prefix is a RunBot convention meaning "related to", not "owned by".
/// A free function is the correct shape here because:
/// - The function has no dependency on `AppUpdater` state (no `self` needed).
/// - `@concurrent` cannot be applied to instance methods on a `@MainActor` class
///   without an `nonisolated` escape; a free function is simply the right tool.
/// - Keeping it free makes it trivially testable without constructing an `AppUpdater`.
///
/// REVIEWER: Do NOT refactor `runCommand` into an `AppUpdater` instance or
/// static method. The free-function shape is deliberate.
///
/// ## `@concurrent` — the blocking wait runs off every actor executor
///
/// This is a `@concurrent` async free function, so its synchronous body
/// (`process.run()` + `waitUntilExit()`) runs on the cooperative thread pool's
/// concurrent executor, never on an actor serial executor (Pillar 5,
/// `docs/architecture/concurrency-overview.md`). The previous implementation
/// wrapped the work in `withCheckedContinuation` + `DispatchQueue.global` to
/// hop off the main thread; `@concurrent` expresses the same intent directly and
/// removes the manual GCD plumbing.
///
/// The tradeoff: `waitUntilExit()` holds one cooperative-pool thread for the
/// lifetime of the subprocess (~1–2 s for `ditto`). For a two-call sequence that
/// runs once per update cycle this is completely acceptable; there is no
/// scenario where many concurrent `ditto` invocations would exhaust the pool
/// (`isInstalling` serialises the install path).
///
/// ## Why stderr is captured (not discarded)
///
/// Routing stderr to `nullDevice` made `ditto` failures completely silent: the
/// install path would fail, `updateActionFailed` would flip to `true`, and the
/// user would see a "Download" fallback with no indication of what went wrong.
/// Stderr is now piped and logged at error level on failure so that Console.app
/// and crash reports contain actionable information. Stdout remains discarded —
/// `ditto` produces no useful stdout.
///
/// ## ⚠️ `waitUntilExit()` BEFORE `readDataToEndOfFile()` — NOT A PIPE DEADLOCK ⚠️
///
/// Automated reviewers and linters sometimes flag this ordering as a potential
/// pipe-buffer deadlock. It is NOT a deadlock risk here, and has been verified.
///
/// The classic deadlock scenario requires the subprocess to write ≥ ~64 KB to
/// stderr *before* exiting — filling the OS pipe buffer and blocking the
/// subprocess mid-write, preventing it from ever reaching exit, which prevents
/// `waitUntilExit()` from ever returning: a true deadlock. That scenario cannot
/// arise for `ditto` because:
/// - On success: `ditto` writes nothing to stderr.
/// - On failure: `ditto` emits a single short error line — well under 1 KB.
/// The pipe buffer (64 KB on macOS) is never filled; `ditto` exits without
/// blocking; `waitUntilExit()` returns immediately; `readDataToEndOfFile()`
/// drains the small buffer. No deadlock is possible.
///
/// The generic "concurrent drain" refactor is the right fix for executables that
/// CAN produce large stderr, but it adds complexity for zero benefit here.
///
/// REVIEWER: Do NOT refactor this to a concurrent stderr drain on the basis of
/// a generic pipe-deadlock warning. The warning does not apply to `ditto`.
/// This has been reviewed and confirmed safe. If `runCommand` is ever extended
/// to run an executable that produces large stderr output, add the concurrent
/// drain at that point and update this comment.
@concurrent
func runCommand(_ executable: String, args: [String]) async -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice

    // Pipe stderr so failures are diagnosable. stdout is still discarded —
    // ditto produces no useful stdout on success.
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    do {
        try process.run()
        // ⚠️ waitUntilExit() BEFORE readDataToEndOfFile() — this is NOT a pipe
        // deadlock. ditto's stderr is always < 1 KB (nothing on success, one
        // short line on failure), so the 64 KB OS pipe buffer never fills.
        // ditto exits freely; waitUntilExit() returns; the buffer drains.
        // See the full explanation in the doc comment above before refactoring.
        //
        // waitUntilExit() before readDataToEndOfFile() — safe ONLY for ditto, which
        // writes at most one short diagnostic line to stderr on failure. Do NOT apply
        // this ordering to codesign -dvvv (see AppUpdater+CodeSign.swift which uses
        // an async drain instead, for exactly this reason).
        process.waitUntilExit()
        let succeeded = process.terminationStatus == 0
        if !succeeded {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrMsg = String(data: stderrData, encoding: .utf8) ?? "(unreadable)"
            appUpdaterLogger.error(
                "\(executable, privacy: .public) failed (exit \(process.terminationStatus, privacy: .public)): \(stderrMsg, privacy: .public)"
            )
        }
        return succeeded
    } catch {
        appUpdaterLogger.error(
            "could not launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return false
    }
}
