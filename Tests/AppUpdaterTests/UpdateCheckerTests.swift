// UpdateCheckerTests.swift
// AppUpdater
import Testing
@testable import AppUpdater

// MARK: - UpdateCheckerTests

@Suite("UpdateChecker")
struct UpdateCheckerTests {

    // MARK: - Straightforward newer

    @Test func newerPatch() {
        #expect(UpdateChecker.isNewer("0.7.1", than: "0.7.0") == true)
    }

    @Test func newerMinor() {
        #expect(UpdateChecker.isNewer("0.8.0", than: "0.7.9") == true)
    }

    @Test func newerMajor() {
        #expect(UpdateChecker.isNewer("1.0.0", than: "0.9.9") == true)
    }

    // MARK: - Two-digit component (the lexicographic trap)

    /// Lexicographic comparison would give "1.10.0" < "1.9.0" — numeric must return true.
    @Test func twoDigitMinorComponent() {
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.0") == true)
    }

    // MARK: - Stable vs beta of same version

    /// A stable release supersedes a beta of the same base version.
    @Test func stableBeatsOwnBeta() {
        #expect(UpdateChecker.isNewer("0.7.1", than: "0.7.1-beta.3") == true)
    }

    /// A beta is NOT newer than the stable of the same version.
    @Test func betaNotNewerThanStable() {
        #expect(UpdateChecker.isNewer("0.7.1-beta.1", than: "0.7.1") == false)
    }

    // MARK: - Beta-to-beta ordering

    /// A higher beta.N should be offered to users already on a lower beta.N
    /// of the same base version. Previously `isNewer` returned `false` here
    /// because major/minor/patch were identical and both `isPrerelease = true`,
    /// silently suppressing beta-to-beta update prompts.
    @Test func newerBetaWithinSameBase() {
        #expect(UpdateChecker.isNewer("0.7.1-beta.2", than: "0.7.1-beta.1") == true)
    }

    @Test func olderBetaWithinSameBase() {
        #expect(UpdateChecker.isNewer("0.7.1-beta.1", than: "0.7.1-beta.2") == false)
    }

    @Test func sameBetaVersion() {
        #expect(UpdateChecker.isNewer("0.7.1-beta.2", than: "0.7.1-beta.2") == false)
    }

    // MARK: - Already up to date

    @Test func sameVersion() {
        #expect(UpdateChecker.isNewer("0.7.0", than: "0.7.0") == false)
    }

    // MARK: - Older

    @Test func olderVersion() {
        #expect(UpdateChecker.isNewer("0.6.9", than: "0.7.0") == false)
    }

    @Test func olderMinor() {
        #expect(UpdateChecker.isNewer("0.7.0", than: "0.8.0") == false)
    }

    @Test func olderMajor() {
        #expect(UpdateChecker.isNewer("0.9.9", than: "1.0.0") == false)
    }

    // MARK: - v-prefix handling

    /// GitHub Releases API always returns tag names with a leading 'v'.
    /// Verifies that ParsedVersion.init strips the prefix before comparing.
    @Test func vPrefixedCandidate() {
        #expect(UpdateChecker.isNewer("v0.8.0", than: "0.7.0") == true)
    }

    @Test func vPrefixedCurrent() {
        #expect(UpdateChecker.isNewer("0.8.0", than: "v0.7.0") == true)
    }

    // MARK: - ParsedVersion empty-input guard (regression)

    /// `"v"` stripped of its prefix yields `""` — `String.split` returns `[]`,
    /// so `parts[0]` would crash without the `parts.isEmpty ? "" : …` guard.
    /// Result must be `false` (a bare "v" is not newer than any real version).
    @Test func barePrefixOnlyCandidate() {
        #expect(UpdateChecker.isNewer("v", than: "0.7.0") == false)
    }

    /// Passing an empty string directly must not crash and must return `false`.
    @Test func emptyStringCandidate() {
        #expect(UpdateChecker.isNewer("", than: "0.7.0") == false)
    }
}
