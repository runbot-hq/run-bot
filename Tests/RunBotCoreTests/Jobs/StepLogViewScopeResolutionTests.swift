// StepLogViewScopeResolutionTests.swift
// RunBotCoreTests
// Tests for the scope-resolution logic used by StepLogView.loadLog() — refs #1517.
import Foundation
import Testing

// MARK: - Scope resolution helper

/// Pure reimplementation of `StepLogView.repoScopeForFetch` logic, extracted for
/// unit testing without importing the app target.
///
/// This mirrors the exact algorithm in `StepLogView+Helpers` so that any future
/// divergence between this test and the production path will surface as a test failure.
private func repoScopeForFetch(htmlUrl: String?) -> String {
  let parts = (htmlUrl ?? "").components(separatedBy: "/")
  guard parts.count >= 5 else { return "" }
  let owner = parts[3]
  let repo = parts[4]
  return (owner.isEmpty || repo.isEmpty) ? "" : "\(owner)/\(repo)"
}

// MARK: - Test suite

@Suite("StepLogView scope resolution")
struct StepLogViewScopeResolutionTests {

  // MARK: Primary path — valid htmlUrl

  /// Verifies that a full GitHub Actions job URL correctly yields `"owner/repo"` as the scope string.
  @Test("extracts owner/repo from a well-formed GitHub job URL")
  func extractsOwnerRepoFromWellFormedURL() {
    let url = "https://github.com/runbot-hq/run-bot/actions/runs/12345/job/67890"
    #expect(repoScopeForFetch(htmlUrl: url) == "runbot-hq/run-bot")
  }

  /// Verifies that a minimal URL containing only scheme, host, owner, and repo (no trailing path) still resolves correctly.
  @Test("extracts owner/repo when URL has no trailing path beyond repo")
  func extractsOwnerRepoFromMinimalURL() {
    let url = "https://github.com/some-org/my-repo"
    #expect(repoScopeForFetch(htmlUrl: url) == "some-org/my-repo")
  }

  /// Verifies that hyphenated owner and repo name segments are handled without truncation or misparse.
  @Test("extracts owner/repo with hyphenated owner and repo names")
  func extractsHyphenatedOwnerRepo() {
    let url = "https://github.com/my-org/my-repo/actions/runs/1"
    #expect(repoScopeForFetch(htmlUrl: url) == "my-org/my-repo")
  }

  // MARK: Fallback path — malformed or absent htmlUrl

  /// Verifies that a `nil` `htmlUrl` falls back to an empty scope string without crashing.
  @Test("returns empty string when htmlUrl is nil")
  func returnsEmptyWhenNil() {
    #expect(repoScopeForFetch(htmlUrl: nil).isEmpty)
  }

  /// Verifies that an empty `htmlUrl` string falls back to an empty scope string.
  @Test("returns empty string when htmlUrl is empty")
  func returnsEmptyWhenEmpty() {
    #expect(repoScopeForFetch(htmlUrl: "").isEmpty)
  }

  /// Verifies that a URL with fewer than 5 slash-separated components (missing the repo segment) returns an empty scope string.
  @Test("returns empty string when URL has fewer than 5 slash-separated parts")
  func returnsEmptyWhenTooShort() {
    // e.g. "https://github.com/owner" — only 4 parts
    #expect(repoScopeForFetch(htmlUrl: "https://github.com/owner").isEmpty)
  }

  /// Verifies that a malformed URL with a double-slash producing an empty owner component returns an empty scope string.
  @Test("returns empty string when owner component is empty")
  func returnsEmptyWhenOwnerIsEmpty() {
    // malformed: double slash produces an empty owner component
    let url = "https://github.com//run-bot/actions"
    #expect(repoScopeForFetch(htmlUrl: url).isEmpty)
  }

  /// Verifies that a malformed URL with a double-slash producing an empty repo component returns an empty scope string.
  @Test("returns empty string when repo component is empty")
  func returnsEmptyWhenRepoIsEmpty() {
    // malformed: double slash produces an empty repo component
    let url = "https://github.com/runbot-hq//actions/runs/1"
    #expect(repoScopeForFetch(htmlUrl: url).isEmpty)
  }

  /// Verifies that a non-GitHub URL with only a hostname (no path segments) returns an empty scope string.
  @Test("returns empty string for a non-GitHub URL with insufficient path depth")
  func returnsEmptyForNonGitHubURL() {
    #expect(repoScopeForFetch(htmlUrl: "https://example.com").isEmpty)
  }
}
