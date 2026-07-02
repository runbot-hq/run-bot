// UpdateCheckerIsNewerTests.swift
// AppUpdaterTests
import Testing
@testable import AppUpdater

// MARK: - UpdateCheckerIsNewerTests

/// Exhaustive matrix tests for `UpdateChecker.isNewer(_:than:)`.
///
/// Each test covers a distinct semver comparison dimension. No async,
/// no network, no `DispatchQueue` (Pillar 5). Pure value-level logic tests.
struct UpdateCheckerIsNewerTests {

    // MARK: - Major

    @Test func majorVersionHigher_returnsTrue() {
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.0.0") == true)
    }

    @Test func majorVersionLower_returnsFalse() {
        #expect(UpdateChecker.isNewer("1.0.0", than: "2.0.0") == false)
    }

    // MARK: - Minor

    @Test func minorVersionHigher_returnsTrue() {
        #expect(UpdateChecker.isNewer("1.1.0", than: "1.0.0") == true)
    }

    @Test func minorVersionLower_returnsFalse() {
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.1.0") == false)
    }

    // MARK: - Patch

    @Test func patchVersionHigher_returnsTrue() {
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0") == true)
    }

    @Test func patchVersionLower_returnsFalse() {
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.1") == false)
    }

    // MARK: - Equal versions

    @Test func identicalVersions_returnsFalse() {
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0") == false)
    }

    // MARK: - v-prefix stripping

    @Test func vPrefixedCandidate_strippedBeforeCompare() {
        #expect(UpdateChecker.isNewer("v2.0.0", than: "1.0.0") == true)
    }

    @Test func vPrefixedCurrent_strippedBeforeCompare() {
        #expect(UpdateChecker.isNewer("2.0.0", than: "v1.0.0") == true)
    }

    @Test func bothVPrefixed_strippedBeforeCompare() {
        #expect(UpdateChecker.isNewer("v2.0.0", than: "v1.0.0") == true)
    }

    // MARK: - Stable vs. pre-release

    /// Stable 1.0.0 must be considered newer than 1.0.0-beta.1.
    @Test func stable_newerThanPrerelease_sameBase() {
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0-beta.1") == true)
    }

    /// A pre-release must not be considered newer than its stable base.
    @Test func prerelease_notNewerThanStable_sameBase() {
        #expect(UpdateChecker.isNewer("1.0.0-beta.1", than: "1.0.0") == false)
    }

    // MARK: - Beta ordering

    /// beta.2 must be newer than beta.1 when the X.Y.Z base is identical.
    @Test func betaIndex2_newerThanBetaIndex1() {
        #expect(UpdateChecker.isNewer("1.0.0-beta.2", than: "1.0.0-beta.1") == true)
    }

    @Test func betaIndex1_notNewerThanBetaIndex2() {
        #expect(UpdateChecker.isNewer("1.0.0-beta.1", than: "1.0.0-beta.2") == false)
    }

    @Test func betaIndex10_newerThanBetaIndex9() {
        #expect(UpdateChecker.isNewer("1.0.0-beta.10", than: "1.0.0-beta.9") == true)
    }

    // MARK: - Cross-version beta vs stable

    /// A beta of a higher version is still newer than the lower stable.
    @Test func higherVersionBeta_newerThanLowerStable() {
        #expect(UpdateChecker.isNewer("2.0.0-beta.1", than: "1.9.9") == true)
    }

    // MARK: - Edge cases

    @Test func emptyStrings_returnsFalse() {
        #expect(UpdateChecker.isNewer("", than: "") == false)
    }

    @Test func singleVPrefix_returnsFalse() {
        #expect(UpdateChecker.isNewer("v", than: "v") == false)
    }

    @Test func partialVersion_twoComponents_comparedCorrectly() {
        // "2.0" parsed as 2.0.0 vs "1.9" parsed as 1.9.0
        #expect(UpdateChecker.isNewer("2.0", than: "1.9") == true)
    }
}
