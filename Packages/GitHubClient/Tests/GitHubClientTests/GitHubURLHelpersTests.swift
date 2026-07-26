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

  // MARK: Happy paths

  /// Repo-scoped URL returns "owner/repo".
  @Test func repoScoped_returnsOwnerSlashRepo() {
    let url = URL(string: "https://github.com/acme/my-repo")!
    #expect(scopeFromUrl(url) == "acme/my-repo")
  }

  /// Org-scoped URL (single path component) returns the org name.
  @Test func orgScoped_returnsOrgName() {
    let url = URL(string: "https://github.com/acme")!
    #expect(scopeFromUrl(url) == "acme")
  }

  /// Trailing slash on a repo URL is handled correctly.
  @Test func repoScoped_trailingSlash_returnsOwnerSlashRepo() {
    let url = URL(string: "https://github.com/acme/my-repo/")!
    #expect(scopeFromUrl(url) == "acme/my-repo")
  }

  // MARK: Percent-encoded path components

  /// Foundation decodes percent-encoding in `pathComponents`, so a URL with
  /// `%20` in the owner segment must return the decoded form "acme corp/my-repo"
  /// rather than the raw escaped string. This ensures callers that match scope
  /// strings against API responses (which are never percent-encoded) work correctly.
  @Test func percentEncodedOwner_returnsDecodedScope() {
    let url = URL(string: "https://github.com/acme%20corp/my-repo")!
    #expect(scopeFromUrl(url) == "acme corp/my-repo")
  }

  // MARK: Query string is ignored

  /// `URL.pathComponents` never includes query parameters.
  /// A URL like `https://github.com/acme/repo?foo=bar` must return "acme/repo"
  /// — the query string must not appear in the scope string or cause an error.
  @Test func queryString_isIgnored() {
    let url = URL(string: "https://github.com/acme/repo?foo=bar")!
    #expect(scopeFromUrl(url) == "acme/repo")
  }

  // MARK: Nil path

  /// A bare host with no path components returns nil.
  @Test func bareHost_returnsNil() {
    let url = URL(string: "https://github.com")!
    #expect(scopeFromUrl(url) == nil)
  }

  /// A bare host with a trailing slash (single "/" component only) returns nil.
  @Test func bareHostTrailingSlash_returnsNil() {
    let url = URL(string: "https://github.com/")!
    #expect(scopeFromUrl(url) == nil)
  }

  /// A URL whose only pathComponent is "/" (e.g. file:// root) returns nil.
  /// This is a portable way to exercise the no-meaningful-components branch.
  @Test func noPathComponentsURL_returnsNil() {
    let url = URL(string: "file:///")!
    #expect(scopeFromUrl(url) == nil)
  }

  // MARK: Empty path component guard (programmatic URL construction)

  /// Verifies that the !$0.isEmpty guard strips empty segments introduced by
  /// URLComponents when a path segment is set to an empty string programmatically.
  /// This is the scenario the guard protects against; string-parsed URLs are
  /// normalised by Foundation before pathComponents is evaluated.
  @Test func emptySegmentViaURLComponents_filtersEmptyComponent() {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "//acme"
    guard let url = components.url else { return }
    #expect(scopeFromUrl(url) == "acme")
  }

  // MARK: 3+ path segments (intentional truncation)

  /// URLs with more than two path segments return only the first two.
  /// This is intentional: GitHub runner URLs are always owner/repo or org.
  @Test func threeSegments_returnsFirstTwo() {
    let url = URL(string: "https://github.com/owner/repo/tree")!
    #expect(scopeFromUrl(url) == "owner/repo")
  }

  @Test func fourSegments_returnsFirstTwo() {
    let url = URL(string: "https://github.com/owner/repo/tree/main")!
    #expect(scopeFromUrl(url) == "owner/repo")
  }

  // MARK: Non-github.com host

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

  // MARK: Happy paths — delegates to scopeFromUrl

  /// Repo-scoped URL string returns "owner/repo".
  @Test func repoScoped_returnsOwnerSlashRepo() {
    #expect(scopeFromHtmlUrl("https://github.com/acme/my-repo") == "acme/my-repo")
  }

  /// Org-scoped URL string returns the org name.
  @Test func orgScoped_returnsOrgName() {
    #expect(scopeFromHtmlUrl("https://github.com/acme") == "acme")
  }

  // MARK: Percent-encoded path components

  /// Foundation decodes percent-encoding in `pathComponents`; the returned scope
  /// must be the decoded form. Mirrors scopeFromUrl's percent-encoding test
  /// through the String? wrapper.
  @Test func percentEncodedOwner_returnsDecodedScope() {
    #expect(scopeFromHtmlUrl("https://github.com/acme%20corp/my-repo") == "acme corp/my-repo")
  }

  // MARK: Query string is ignored

  /// Query parameters must not appear in the returned scope string.
  /// Mirrors scopeFromUrl's queryString_isIgnored test through the String? wrapper.
  @Test func queryString_isIgnored() {
    #expect(scopeFromHtmlUrl("https://github.com/acme/repo?foo=bar") == "acme/repo")
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
