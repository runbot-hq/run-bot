// ProcessRunnerTests.swift
// RunBotCoreTests
import Foundation
import Testing
@testable import RunBotCore

// MARK: - ProcessRunner.runAsync stdin

@Suite("ProcessRunner.runAsync stdin")
struct ProcessRunnerRunAsyncStdinTests {

  @Test(.timeLimit(.minutes(1)))
  func runAsyncStdinSmallPayloadRoundtrip() async {
    let input = "hello stdin"
    let data = Data(input.utf8)
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      stdin: data
    )
    #expect(result.exitCode == 0)
    #expect(result.output == input)
  }

  @Test(.timeLimit(.minutes(1)))
  func runAsyncStdinLargePayloadRoundtrip() async {
    let input = String(repeating: "x", count: 1_024 * 1_024)
    let data = Data(input.utf8)
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      stdin: data
    )
    #expect(result.exitCode == 0)
    #expect(result.output.count == input.count)
  }

  @Test(.timeLimit(.minutes(1)))
  func runAsyncNonZeroExitCode() async {
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"),
      arguments: [],
      stdin: nil
    )
    #expect(result.exitCode == 1)
  }

  /// #1983 Step 5 — A process that writes to stderr must complete normally.
  /// The exit code must reflect the process result (non-zero here) and the
  /// runner must not hang waiting for stderr to drain.
  ///
  /// ProcessRunner discards stderr — it is not captured or exposed to callers.
  /// This satisfies the audit requirement to either assert stderr content or
  /// explicitly document that it is not captured.
  @Test(.timeLimit(.minutes(1)))
  func runAsyncStderrDoesNotHang() async {
    // /bin/sh writes "err" to stderr then exits 1.
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo err >&2; exit 1"],
      stdin: nil
    )
    #expect(result.exitCode == 1, "process exit code must be 1")
    // stdout must be empty — the message went to stderr, not stdout.
    // ProcessRunner discards stderr; only stdout is returned in result.output.
    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "stdout must be empty when output is written only to stderr")
  }

}
