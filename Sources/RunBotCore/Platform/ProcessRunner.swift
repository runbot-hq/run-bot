// ProcessRunner.swift
// RunBotCore
import Foundation
import os

// MARK: - ProcessRunner

// Shared primitive for launching subprocesses with streaming output,
// optional stdin, optional working directory, and structured-concurrency timeout handling.
//
// Both `runRegistrationCommand` and `runScriptWithOutput`
// (RunnerLifecycleService) are thin wrappers around this type.
//
// ## Migration note (from Shell.swift — deleted in #956)
// The old `Shell` enum used `/bin/zsh -c "<command string>"` which had
// a documented shell-injection risk: any unsanitised argument could escape
// the command string and execute arbitrary shell code. `ProcessRunner.run`
// takes a typed `[String]` arguments array and passes it directly to
// `Process`, bypassing the shell entirely. Never reintroduce a string-based
// shell invocation here.
//
// ## Async variant (`runAsync`)
// `runAsync` owns its own `Process` instance and bridges completion via
// `terminationHandler` + `withCheckedContinuation` — no thread is held while
// the subprocess runs. `withTaskCancellationHandler` wires `task.terminate()`
// directly to Swift structured concurrency cancellation, and a sibling
// `Task.detached` uses `Task.sleep(for:)` to enforce the timeout without
// GCD-managed timer state.
//
// Migration (#1365/#1366): the legacy synchronous `run()` path was removed.
// `OSAllocatedUnfairLock` replaces `Box<T>: @unchecked Sendable` throughout;
// the lock is a `let` constant captured by `@Sendable` closures — `withLock`
// provides compiler-verified `Sendable` conformance with the same
// queue-serialised happens-before semantics.

/// Shared primitive for launching subprocesses. See file-level doc comment above for full details.
public enum ProcessRunner {
    /// The collected output and exit status from a subprocess invocation.
    public struct Result {
        /// Collected stdout bytes, or `nil` when the process failed to launch
        /// or when the process ran successfully but produced no stdout.
        /// - Note: `nil` does not imply failure — use `exitCode` to distinguish
        ///   a launch failure (`Int32.max`) from a successful process that produced no output.
        public let data: Data?
        /// Process exit code. `Int32.max` indicates a launch failure rather than a process exit.
        public let exitCode: Int32
        /// Convenience: decoded UTF-8 string of `data`, or empty string.
        public var output: String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    // MARK: - Async

    /// Launches an executable asynchronously without blocking the cooperative thread pool.
    ///
    /// This method owns its `Process` instance directly so that Swift structured
    /// concurrency can interact with it properly:
    ///
    /// - **Suspension:** the caller suspends at the `await` and is resumed by
    ///   `terminationHandler` when the process exits — no thread is held.
    /// - **Cancellation:** `withTaskCancellationHandler` calls `task.terminate()`
    ///   the moment the enclosing `Task` is cancelled (e.g. when `start()` replaces
    ///   `pollTask`), bounding latency to OS signal-delivery time rather than the
    ///   full `timeout`.
    /// - **Timeout:** a sibling `Task.detached` sleeps for `timeout` seconds and
    ///   then calls `task.terminate()` if the process is still running, preserving
    ///   hang-safety without a `DispatchWorkItem`. The timeout task is intentionally
    ///   `Task.detached` — it must outlive the `withCheckedContinuation` scope and
    ///   run regardless of the parent task's cancellation state. Its lifetime is
    ///   bounded by the earlier of: (a) `terminationHandler` cancelling it after
    ///   process exit, or (b) the `timeout` interval elapsing.
    ///
    /// ## ⚠️ Pipe-drain concurrency
    /// stdout is drained via a dedicated serial `DispatchQueue` *concurrently* with
    /// process execution (concurrent drain + `terminationHandler` join pattern).
    /// `readDataToEndOfFile()` blocks until the pipe's write end closes (i.e. the
    /// process exits), so all bytes are captured in a single call with one clear
    /// happens-before edge. `terminationHandler` joins the drain queue with
    /// `drainQueue.sync {}` before reading the result — no actor, no lock, no
    /// fire-and-forget tasks required.
    ///
    /// ## stdin ordering
    /// When `stdin` data is provided, it is written on a dedicated serial
    /// `stdinQueue` that is dispatched *after* `drainQueue.async` and *after*
    /// `task.run()`. The ordering guarantee is:
    ///
    /// 1. `drainQueue.async { readDataToEndOfFile }` — drain starts, blocks until
    ///    the write end of stdout closes (i.e. the child exits).
    /// 2. `task.run()` — child process launches and begins consuming stdin.
    /// 3. `stdinQueue.async { [inputPipe] write + closeFile }` — stdin bytes are fed
    ///    to the child concurrently as it runs. `closeFile()` signals EOF once all
    ///    bytes have been written. The child may exit before or after the write
    ///    completes; either way `drainQueue.sync {}` in `terminationHandler` joins
    ///    stdout first.
    ///
    /// ⚠️ **SIGPIPE / crash risk for future callers:** `FileHandle.write(_:)` is
    /// non-throwing. On macOS 10.15.4+, if the child process exits before consuming
    /// all stdin, the OS delivers `SIGPIPE` to the writing thread, which **crashes**
    /// the process rather than throwing an error. This is safe for callers like
    /// `/bin/cat` that always consume their full input, but future callers whose
    /// child may exit early should use a `writeabilityHandler`-based writer that
    /// can detect and handle a broken pipe without crashing.
    ///
    /// This approach:
    /// - Does **not** block a cooperative thread pool worker (no synchronous write
    ///   before `task.run()`, fixing the pre-launch deadlock for payloads > ~64 KB).
    /// - Does **not** race against `terminationHandler` (fixes #1077/#1228): `stdinQueue`
    ///   is a separate serial queue from `drainQueue`; the drain joins its own queue
    ///   via `drainQueue.sync {}` without depending on stdin completion.
    /// - Handles arbitrarily large stdin payloads — the child drains the pipe
    ///   concurrently as `stdinQueue` feeds bytes in.
    ///
    /// ## ⚠️ Do NOT add DispatchGroup.wait() to join stdinQueue in terminationHandler
    /// This has been suggested by automated reviewers. It is the wrong approach for
    /// two reasons:
    ///
    /// 1. **Modernisation mandate (#1220):** This file is part of a migration away from
    ///    GCD-era primitives toward Swift structured concurrency. Adding a
    ///    `DispatchGroup.wait()` inside a `DispatchQueue` callback would introduce
    ///    *more* nested GCD synchronisation — the exact anti-pattern being eliminated.
    ///
    /// 2. **It is unnecessary:** `terminationHandler` fires only after the child process
    ///    has exited. A process cannot exit while its stdin pipe write-end is open and
    ///    actively blocking — by the time `terminationHandler` is called, `stdinQueue`
    ///    has either completed the write or the pipe's broken-pipe signal has already
    ///    been handled by the OS. The only invariant that *must* hold before resuming
    ///    the continuation is that stdout is fully captured — which `drainQueue.sync {}`
    ///    already guarantees.
    ///
    /// All parameters and defaults are identical to the removed synchronous `run()` method.
    ///
    /// The `withCheckedContinuation` body is delegated to `launchAndAwait` to keep
    /// `runAsync`'s cyclomatic complexity within the SW-R1002 threshold (see #1697).
    public static func runAsync(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval = 20
    ) async -> Result {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        if let workingDirectory { task.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = mergeStderr ? outPipe : FileHandle.nullDevice

        let inputPipe = wireStdin(hasStdin: stdin != nil, to: task)

        // Drain stdout on a dedicated serial queue concurrently with process execution,
        // (concurrent drain + terminationHandler join pattern). readDataToEndOfFile() blocks until
        // the write end of the pipe is closed (i.e. the process exits), so it captures
        // all output in one call with a single clear happens-before edge.
        //
        // Using a DispatchQueue here (not a Task) keeps the drain off the cooperative
        // thread pool, avoids the fire-and-forget Task.detached-per-chunk pattern, and
        // ensures drainQueue.sync {} in terminationHandler is the sole synchronisation
        // point. `outputBox` is an `OSAllocatedUnfairLock` for Swift 6 `Sendable`
        // compliance — the lock is held only for the brief Data assignment/read;
        // the queue's `sync {}` barrier, not the lock, is the happens-before edge.
        let outputBox = OSAllocatedUnfairLock(initialState: Data())
        let drainQueue = DispatchQueue(label: "ProcessRunner.drain.async")

        // Dedicated serial queue for stdin writes. Dispatched after task.run() so the
        // child is already running and consuming the read end of inputPipe. This prevents
        // the pre-launch deadlock for payloads > kernel pipe buffer (~64 KB) that the
        // previous synchronous-write approach introduced. See doc comment above.
        //
        // UUID suffix: each runAsync call gets a uniquely labelled queue so that
        // concurrent invocations are distinguishable in Instruments and lldb thread list.
        let stdinQueue: DispatchQueue? = (inputPipe != nil)
            ? DispatchQueue(label: "ProcessRunner.stdin.async.\(UUID().uuidString)")
            : nil

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                drainQueue.async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    outputBox.withLock { $0 = data }
                }

                // Timeout guard — terminates the process if it outlives `timeout`.
                // OSAllocatedUnfairLock is used so terminationHandler (a @Sendable closure)
                // can capture a reference type (let) rather than a var, satisfying Swift 6.2
                // strict concurrency. The lock is held only for the brief assignment/read.
                // The box is written once after task.run() and read once inside
                // terminationHandler — both on the same serialised execution path (#1152).
                let timeoutTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

                task.terminationHandler = { [outputBox] process in
                    Self.handleTermination(
                        process: process,
                        executableName: executableURL.lastPathComponent,
                        outputBox: outputBox,
                        drainQueue: drainQueue,
                        timeoutTaskBox: timeoutTaskBox,
                        continuation: continuation
                    )
                }

                let context = LaunchContext(
                    stdin: stdin,
                    outPipe: outPipe,
                    inputPipe: inputPipe,
                    stdinQueue: stdinQueue,
                    timeoutTaskBox: timeoutTaskBox,
                    continuation: continuation,
                    timeout: timeout
                )
                launchAndAwait(task: task, executableURL: executableURL, arguments: arguments, context: context)
            }
        } onCancel: {
            // Enclosing Task was cancelled (e.g. pollTask replaced by start()).
            // terminate() signals the subprocess; terminationHandler fires and resumes
            // the continuation, so the awaiting Task unblocks and exits cleanly.
            //
            // Swift docs: if the task is already cancelled when withTaskCancellationHandler
            // is called, onCancel fires synchronously *before* the operation closure runs.
            // In that case task.run() has not been called yet — isRunning is false and
            // terminate() would be a no-op on Darwin, but the process would then start
            // normally when the operation eventually runs, violating cancellation semantics.
            // The guard ensures we only signal a live process, and the Task.isCancelled
            // check at the top of the operation catches the already-cancelled path before
            // task.run() is reached.
            guard task.isRunning else { return }
            task.terminate()
        }
    }

    // MARK: - Private helpers

    /// Bundles the pipe, queue, and continuation values passed to `launchAndAwait`.
    ///
    /// Grouping these into a struct keeps `launchAndAwait`'s parameter count within
    /// the SwiftLint `function_parameter_count` limit (≤ 6) while preserving the
    /// same explicit ownership and Sendable guarantees as the individual parameters.
    private struct LaunchContext {
        /// Optional bytes to write to the subprocess's stdin after launch.
        /// `nil` means no stdin is needed; the input pipe is left unattached.
        let stdin: Data?
        /// Pipe whose read end is attached to the subprocess's stdout (and stderr
        /// when `mergeStderr` is true). The drain queue reads from this pipe.
        let outPipe: Pipe
        /// Pipe whose write end feeds the subprocess's stdin, or `nil` when
        /// `stdin` is `nil`. Created by `wireStdin(hasStdin:to:)`.
        let inputPipe: Pipe?
        /// Serial `DispatchQueue` on which stdin bytes are written after `task.run()`.
        /// `nil` when no stdin data is provided.
        let stdinQueue: DispatchQueue?
        /// Lock-protected box holding the timeout `Task` handle so that
        /// `terminationHandler` can cancel it after the process exits.
        let timeoutTaskBox: OSAllocatedUnfairLock<Task<Void, Never>?>
        /// Continuation that resumes the `runAsync` caller once the subprocess
        /// exits (or fails to launch).
        let continuation: CheckedContinuation<Result, Never>
        /// Maximum wall-clock seconds the subprocess is allowed to run before
        /// the timeout task calls `task.terminate()`.
        let timeout: TimeInterval
    }

    /// Attaches a stdin pipe to `task` when stdin data is present.
    ///
    /// Returns the `Pipe` whose write end the caller must feed data to (and then
    /// close) after `task.run()`, or `nil` when no stdin is needed.
    /// Extracted from `runAsync` so any future `Process`-launching method can
    /// reuse the same setup without copy-pasting the three-line wiring block.
    ///
    /// - Note: The `Bool` parameter intentionally accepts a pre-evaluated presence
    ///   check (`stdin != nil`) rather than the raw `Data?`. The helper only needs
    ///   to know *whether* stdin is required; the actual data is consumed by the
    ///   caller's `stdinQueue` block after `task.run()`. This makes the
    ///   "presence-only" contract explicit and avoids misleading readers into
    ///   thinking the data is written here.
    ///   See also the ⚠️ SIGPIPE warning in `runAsync` — any caller that retains
    ///   the returned `Pipe` and writes to it inherits that risk.
    private static func wireStdin(hasStdin: Bool, to task: Process) -> Pipe? {
        guard hasStdin else { return nil }
        let pipe = Pipe()
        task.standardInput = pipe
        return pipe
    }

    /// Handles `Process.terminationHandler` for `runAsync`.
    ///
    /// Extracted from the `withCheckedContinuation` body so the nesting depth inside
    /// `runAsync` stays at ≤ 3 (withTaskCancellationHandler → withCheckedContinuation
    /// → terminationHandler assignment), satisfying the SonarCloud
    /// `FunctionNestingDepth:3` threshold.
    ///
    /// ## Concurrency contract
    /// `terminationHandler` is called on an arbitrary Foundation thread — not on
    /// the cooperative thread pool. All shared state (`outputBox`, `timeoutTaskBox`)
    /// is guarded by `OSAllocatedUnfairLock`; no structured-concurrency isolation
    /// is assumed or required here.
    ///
    /// ## DispatchQueue.sync rationale — last GCD sync in the production path
    /// `drainQueue.sync {}` is an intentional empty barrier that blocks the
    /// `terminationHandler` thread until the `drainQueue.async { readDataToEndOfFile() }`
    /// block in `runAsync` has completed. This establishes the happens-before edge
    /// that makes `outputBox` safe to read on the next line.
    ///
    /// **Why not replace this with structured concurrency?**
    /// The drain deliberately runs on a `DispatchQueue` (not a `Task`) to keep
    /// `readDataToEndOfFile()` off the cooperative thread pool — a blocking call
    /// on a pool worker would starve other tasks. The `drainQueue.sync {}` join
    /// here is therefore the correct and intended cross-boundary synchronisation
    /// point. Migrating away from it would require a fundamentally different drain
    /// architecture (e.g. `AsyncBytes`) and is tracked as a Principle-2 audit item.
    ///
    /// **This is the last remaining `DispatchQueue.sync` in the production code
    /// path.** It is preserved intentionally; do not remove it without a full
    /// Principle-2 audit of the drain and terminationHandler lifecycle.
    ///
    /// See the `runAsync` doc comment for why `stdinQueue` is *not* joined here.
    private static func handleTermination(
        process: Process,
        executableName: String,
        outputBox: OSAllocatedUnfairLock<Data>,
        drainQueue: DispatchQueue,
        timeoutTaskBox: OSAllocatedUnfairLock<Task<Void, Never>?>,
        continuation: CheckedContinuation<Result, Never>
    ) {
        let exitCode = process.terminationStatus
        // Cancel the timeout guard — process already exited.
        // Read under lock, cancel outside: avoids holding the unfair lock during Task.cancel().
        let timeoutTask = timeoutTaskBox.withLock { $0 }
        timeoutTask?.cancel()
        // Empty sync barrier — blocks until drainQueue's readDataToEndOfFile() finishes.
        // This is the sole happens-before edge; no work belongs inside the closure.
        // See doc comment above for why this DispatchQueue.sync is intentionally retained.
        drainQueue.sync {}
        let outputData = outputBox.withLock { $0 }
        log("ProcessRunner › exit=\(exitCode) bytes=\(outputData.count) — \(executableName)", category: .services)
        continuation.resume(returning: Result(
            data: outputData.isEmpty ? nil : outputData,
            exitCode: exitCode
        ))
    }

    /// Executes the core launch sequence inside a `withCheckedContinuation` body.
    ///
    /// Extracted from `runAsync` to reduce its cyclomatic complexity (SW-R1002 / #1697).
    /// Pipe/queue/continuation state is passed as a single `LaunchContext` value to
    /// satisfy the SwiftLint `function_parameter_count` limit (≤ 6).
    ///
    /// All branching that was previously inline in `runAsync`'s continuation body
    /// now lives here:
    ///
    /// - **Already-cancelled guard:** checks `Task.isCancelled` before `task.run()`
    ///   to honour Swift's contract that `onCancel` may fire *before* the operation
    ///   closure when the task is cancelled at the `withTaskCancellationHandler` call site.
    /// - **Launch / error path:** `do { try task.run() } catch` — closes both pipe
    ///   write-ends on failure so the already-dispatched drain receives EOF cleanly.
    /// - **Stdin dispatch:** conditionally enqueues the stdin write on `stdinQueue`
    ///   *after* `task.run()` to avoid the pre-launch pipe-buffer deadlock.
    /// - **Timeout task:** spawns a `Task.detached` that terminates the process
    ///   after `timeout` seconds, then writes the task handle into `timeoutTaskBox`
    ///   so `terminationHandler` can cancel it on process exit.
    ///
    /// No behaviour change — all ordering guarantees and concurrency contracts
    /// documented in `runAsync`'s doc comment are preserved verbatim.
    ///
    /// - Important: Must be called synchronously from within the
    ///   `withCheckedContinuation` closure (i.e. on the same cooperative-thread-pool
    ///   context as `runAsync`) so that `Task.isCancelled` reflects the enclosing
    ///   task's cancellation state correctly.
    private static func launchAndAwait(
        task: Process,
        executableURL: URL,
        arguments: [String],
        context: LaunchContext
    ) {
        // Guard against the already-cancelled case: Swift invokes onCancel
        // *before* this operation closure when the task is cancelled at the
        // moment withTaskCancellationHandler is called. onCancel's
        // `guard task.isRunning` no-ops in that scenario, so we must also
        // bail here before task.run() to honour cancellation rather than
        // launching the process normally.
        if Task.isCancelled {
            context.outPipe.fileHandleForWriting.closeFile()
            context.continuation.resume(returning: Result(data: nil, exitCode: Int32.max))
            return
        }

        do {
            try task.run()
        } catch {
            log("ProcessRunner › launch error: \(error) — \(executableURL.lastPathComponent) \(arguments.joined(separator: " "))", category: .services)
            // Close both pipe write-ends so that any already-dispatched drain
            // block receives EOF and returns cleanly. outPipe must be closed to
            // unblock the drainQueue.async readDataToEndOfFile() call above.
            // inputPipe is closed explicitly here (mirrors outPipe) even though
            // ARC would close it on dealloc — being explicit documents intent
            // and avoids leaving a half-open pipe handle until the next ARC cycle.
            context.outPipe.fileHandleForWriting.closeFile()
            context.inputPipe?.fileHandleForWriting.closeFile()
            context.continuation.resume(returning: Result(data: nil, exitCode: Int32.max))
            return
        }

        // Dispatch stdin write after task.run() — the child is now running and
        // will consume bytes from the read end concurrently. This is safe for
        // arbitrarily large payloads: the child drains the pipe buffer as we fill
        // it. closeFile() signals EOF to the child once all bytes are written.
        //
        // Explicit [inputPipe] capture: inputPipe is a Pipe reference retained
        // by this closure until stdinQueue drains. The capture list makes the
        // lifetime management visible rather than implicit.
        if let stdinQueue = context.stdinQueue, let inputPipe = context.inputPipe, let stdinData = context.stdin {
            stdinQueue.async { [inputPipe] in
                inputPipe.fileHandleForWriting.write(stdinData)
                inputPipe.fileHandleForWriting.closeFile()
            }
        }

        // Create the Task *before* acquiring the lock so it is already
        // scheduled by the time timeoutTaskBox is written.
        //
        // Two benign races exist here:
        //
        // 1. Fast-exit: terminationHandler fires before timeoutTaskBox is
        //    written — it reads nil and skips .cancel(). The timeout task
        //    then fires later but finds task.isRunning == false and exits
        //    without calling terminate(). Safe.
        //
        // 2. Slow-exit: the process outlives the timeout, terminate() is
        //    called by the timeout task, then terminationHandler fires and
        //    reads timeoutTaskBox — but by then the timeout task has already
        //    finished (it returned after terminate()), so .cancel() is a
        //    benign no-op on a completed Task. Safe.
        //
        // In both cases guard task.isRunning is the invariant that prevents
        // a double-terminate. This race existed in the pre-refactor Box<T>
        // code as well (#1152).
        let timeout = context.timeout
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: .seconds(timeout))
                guard task.isRunning else { return }
                log("ProcessRunner › timeout (\(timeout)s) — terminating \(executableURL.lastPathComponent)", category: .services)
                task.terminate()
            } catch {
                // CancellationError from timeoutTask.cancel() — process already done.
            }
        }
        context.timeoutTaskBox.withLock { $0 = timeoutTask }
    }
}
