// LogFetcherTests.swift
// RunBotCoreTests

import Foundation
import GitHubClient
import Testing

@testable import RunBotCore

// MARK: - LogFetcherTests

/// Tests for `LogFetcher` using a `StubTransport`.
@Suite("LogFetcher")
struct LogFetcherTests {

  // MARK: - fetchJobLog

  /// Returns `nil` when scope is an org name without `/`.
  @Test func fetchJobLog_orgScope_returnsNil() async {
    let f = LogFetcher(transport: StubTransport())
    let result = await f.fetchJobLog(jobID: 1, scope: "myorg")
    #expect(result == nil)
  }

  /// Returns `nil` when the transport returns `nil`.
  @Test func fetchJobLog_transportReturnsNil_returnsNil() async {
    let f = LogFetcher(transport: StubTransport())
    let result = await f.fetchJobLog(jobID: 1, scope: "owner/repo")
    #expect(result == nil)
  }

  /// Returns plain text when transport returns valid log bytes.
  @Test func fetchJobLog_validResponse_returnsText() async {
    let t = StubTransport(responses: [
      "repos/owner/repo/actions/jobs/42/logs": Data("Hello, world!".utf8)
    ])
    let f = LogFetcher(transport: t)
    let result = await f.fetchJobLog(jobID: 42, scope: "owner/repo")
    #expect(result == "Hello, world!")
  }

  /// Returns `nil` when the response body starts with `{` (JSON error).
  @Test func fetchJobLog_jsonError_returnsNil() async {
    let t = StubTransport(responses: [
      "repos/owner/repo/actions/jobs/1/logs": Data(
        #"{"message":"Not Found","documentation_url":"..."}"#.utf8)
    ])
    let f = LogFetcher(transport: t)
    let result = await f.fetchJobLog(jobID: 1, scope: "owner/repo")
    #expect(result == nil)
  }

  // MARK: - fetchActionLogs

  /// Returns `nil` when scope is an org name without `/`.
  @Test func fetchActionLogs_orgScope_returnsNil() async {
    let group = WorkflowActionGroup(
      headSha: "sha", label: "sha", title: "", headBranch: nil,
      repo: "myorg", runs: [], jobs: [],
      firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
      isDimmed: false
    )
    let f = LogFetcher(transport: StubTransport())
    let result = await f.fetchActionLogs(group: group)
    #expect(result == nil)
  }

  /// Returns `nil` when the group has no runs.
  @Test func fetchActionLogs_emptyRuns_returnsNil() async {
    let group = WorkflowActionGroup(
      headSha: "sha", label: "sha", title: "", headBranch: nil,
      repo: "owner/repo", runs: [], jobs: [],
      firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
      isDimmed: false
    )
    let f = LogFetcher(transport: StubTransport())
    let result = await f.fetchActionLogs(group: group)
    #expect(result == nil)
  }

  /// Returns `nil` when the transport returns `nil` for a run's logs.
  @Test func fetchActionLogs_transportReturnsNil_returnsNil() async {
    let run = WorkflowRunRef(
      id: 100, name: "CI", status: .completed, conclusion: .success, htmlUrl: nil)
    let group = WorkflowActionGroup(
      headSha: "sha", label: "sha", title: "", headBranch: nil,
      repo: "owner/repo", runs: [run], jobs: [],
      firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
      isDimmed: false
    )
    let t = StubTransport()  // no responses registered → returns nil
    let f = LogFetcher(transport: t)
    let result = await f.fetchActionLogs(group: group)
    #expect(result == nil)
  }

  /// Calls `transport.raw` once per run in the group.
  @Test func fetchActionLogs_callsTransportPerRun() async {
    let runs = [1, 2, 3].map {
      WorkflowRunRef(id: $0, name: "Job \($0)", status: .inProgress, conclusion: nil, htmlUrl: nil)
    }
    let group = WorkflowActionGroup(
      headSha: "sha", label: "sha", title: "", headBranch: nil,
      repo: "owner/repo", runs: runs, jobs: [],
      firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
      isDimmed: false
    )
    let t = StubTransport()  // returns nil for all endpoints
    let f = LogFetcher(transport: t)
    let result = await f.fetchActionLogs(group: group)
    // 3 runs → 3 raw calls, all return nil → unzipLogs not called → empty result
    #expect(result == nil)
    #expect(t.callCount == 3)
  }
}
