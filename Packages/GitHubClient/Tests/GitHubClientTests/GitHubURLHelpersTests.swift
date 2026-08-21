// GitHubURLHelpersTests.swift
// GitHubClientTests
//
// Covers the canonical scope-derivation helpers introduced in F-52:
//   scopeFromUrl(_ url: URL) -> String?
//   scopeFromHtmlUrl(_ urlString: String?) -> String?
//
// Both functions are pure and synchronous — no async, no concurrency helpers needed.
//
// Platform note: Foundation on Linux normalises double-slash paths in URL(string:)
// before building the URL object, so https://github.com//acme becomes
// https://github.com/acme and pathComponents never contains an empty component
// for string-parsed URLs. The !$0.isEmpty guard in scopeFromUrl therefore
// protects against URLs constructed programmatically (e.g. via URLComponents
// with an empty path segment), not string-parsed ones. Tests below verify the
// observable contract using portable well-formed inputs.
//
// Platform note 2: Foundation on both macOS and Linux accepts bare word strings
// (even with spaces) as relative URLs, so there is no portable string input to
// URL(string:) that reliably returns nil. The nil/invalid input path is instead
// covered by bareHostString_returnsNil and noPathComponentsURL_returnsNil.

import Foundation
import Testing

@testable import GitHubClient

// MARK: - scopeFromUrl

@Suite("scopeFromUrl")
struct ScopeFromUrlTests {

  // MARK: Standard URL shapes (matrix)

  /// Consolidates repo, org, trailing-slash, percent-encoded, query-string,
  /// bare-host nil paths, empty-segment, and truncation cases into one matrix.
  @Test func standardURLShapesResolveScope() {
    // (urlString, expected) — nil expected means scopeFromUrl should return nil.
    let cases: [(url: URL, expected: String?)] = [
      (URL(string: "https://github.com/acme/my-repo")!,       "acme/my-repo"),
      (URL(string: "https://github.com/acme")!,               "acme"),
      (URL(string: "https://github.com/acme/my-repo/")!,      "acme/my-repo"),
      (URL(string: "https://github.com/acme%20corp/my-repo")!, "acme corp/my-repo"),
      (URL(string: "https://github.com/acme/repo?foo=bar")!,  "acme/repo"),
      (URL(string: "https://github.com")!,                    nil),
      (URL(string: "https://github.com/")!,                   nil),
      (URL(string: "file:///")!,                              nil),
      (URL(string: "https://github.com/owner/repo/tree")!,    "owner/repo"),
      (URL(string: "https://github.com/owner/repo/tree/main")!, "owner/repo"),
    ]
    for testCase in cases {
      #expect(scopeFromUrl(testCase.url) == testCase.expected,
              "url=\(testCase.url)")
    }
  }

  /// Verifies the !$0.isEmpty guard strips empty segments from programmatic URLComponents construction.
  @Test func emptySegmentViaURLComponents_filtersEmptyComponent() {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "//acme"
    guard let url = components.url else { return }
    #expect(scopeFromUrl(url) == "acme")
  }

  // MARK: Non-github.com host (separate: host compatibility is distinct from path parsing)

  /// Works identically for non-github.com hosts (e.g. GitHub Enterprise).
  @Test func enterpriseHost_repoScoped_returnsOwnerSlashRepo() {
    let url = URL(string: "https://github.corp.example.com/owner/repo")!
    #expect(scopeFromUrl(url) == "owner/repo")
  }

  @Test func enterpriseHost_orgScoped_returnsOrgName() {
    let url = URL(string: "https://github.corp.example.com/myorg")!
    #expect(scopeFromUrl(url) == "myorg")
  }
}

// MARK: - scopeFromHtmlUrl

@Suite("scopeFromHtmlUrl")
struct ScopeFromHtmlUrlTests {

  // MARK: Happy paths — standard shapes (matrix)

  /// Consolidates repo, org, percent-encoded, and query-string cases.
  @Test func standardStringShapesResolveScope() {
    let cases: [(input: String, expected: String)] = [
      ("https://github.com/acme/my-repo",       "acme/my-repo"),
      ("https://github.com/acme",               "acme"),
      ("https://github.com/acme%20corp/my-repo", "acme corp/my-repo"),
      ("https://github.com/acme/repo?foo=bar",  "acme/repo"),
    ]
    for testCase in cases {
      #expect(scopeFromHtmlUrl(testCase.input) == testCase.expected,
              "input=\(testCase.input)")
    }
  }

  // MARK: Nil / no-scope input

  /// nil input returns nil.
  @Test func nilInput_returnsNil() {
    #expect(scopeFromHtmlUrl(nil) == nil)
  }

  /// Empty string — URL(string: "") returns nil on all platforms.
  @Test func emptyString_returnsNil() {
    #expect(scopeFromHtmlUrl("") == nil)
  }

  /// A bare host string with no path returns nil.
  @Test func bareHostString_returnsNil() {
    #expect(scopeFromHtmlUrl("https://github.com") == nil)
  }

  /// A file-root URL string has no meaningful path components; returns nil.
  @Test func fileRootString_returnsNil() {
    #expect(scopeFromHtmlUrl("file:///") == nil)
  }

  // MARK: Consistency with scopeFromUrl

  /// scopeFromHtmlUrl and scopeFromUrl return the same result for the same URL.
  @Test func consistencyWithScopeFromUrl_repoScoped() {
    let urlString = "https://github.com/acme/my-repo"
    let url = URL(string: urlString)!
    #expect(scopeFromHtmlUrl(urlString) == scopeFromUrl(url))
  }

  @Test func consistencyWithScopeFromUrl_orgScoped() {
    let urlString = "https://github.com/acme"
    let url = URL(string: urlString)!
    #expect(scopeFromHtmlUrl(urlString) == scopeFromUrl(url))
  }

  /// nil input is a boundary that scopeFromUrl cannot receive (URL is non-optional);
  /// scopeFromHtmlUrl must return nil for it. Anchors the nil boundary alongside
  /// the other consistency checks.
  @Test func consistencyWithScopeFromUrl_nilInput() {
    #expect(scopeFromHtmlUrl(nil) == nil)
  }

  /// Empty string: anchor the Foundation contract that URL(string: "") returns nil
  /// explicitly, so a future SDK change that makes it non-nil surfaces here rather
  /// than as a confusing downstream mismatch in scopeFromHtmlUrl's return value.
  @Test func consistencyWithScopeFromUrl_emptyString() {
    #expect(URL(string: "") == nil, "Foundation contract: URL(string: \"\") must be nil")
    #expect(scopeFromHtmlUrl("") == nil)
  }
}
