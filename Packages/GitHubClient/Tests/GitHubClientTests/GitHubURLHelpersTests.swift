// GitHubURLHelpersTests.swift
// GitHubClientTests
//
// Two contracts cover the full observable surface of the URL-scope helpers:
//
//  urlScopeContract       - scopeFromUrl: org, repo, decode, truncation,
//                           enterprise host, invalid path
//  htmlURLParsingContract - scopeFromHtmlUrl: nil, empty, invalid, valid string
//
import Testing
import Foundation
@testable import GitHubClient

@Suite("GitHub URL scope")
struct GitHubURLScopeTests {

    @Test
    func urlScopeContract() {
        let cases: [(input: String, expected: String?)] = [
            ("https://github.com/acme",                "acme"),
            ("https://github.com/acme/repo",           "acme/repo"),
            ("https://github.com/acme%20corp/repo",    "acme corp/repo"),
            ("https://github.com/acme/repo/tree/main", "acme/repo"),
            ("https://github.example/acme/repo",       "acme/repo"),
            ("https://github.com",                     nil),
        ]
        for testCase in cases {
            let url = URL(string: testCase.input)!
            #expect(
                scopeFromUrl(url) == testCase.expected,
                #"input=\#(testCase.input)"#
            )
        }
    }

    @Test
    func htmlURLParsingContract() {
        let cases: [(input: String?, expected: String?)] = [
            (nil,                            nil),
            ("",                             nil),
            ("://bad",                       nil),
            ("https://github.com/acme/repo", "acme/repo"),
        ]
        for testCase in cases {
            #expect(
                scopeFromHtmlUrl(testCase.input) == testCase.expected,
                #"input=\#(String(describing: testCase.input))"#
            )
        }
    }
}
