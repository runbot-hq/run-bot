// MBKMenuBarVisibilityLeaseTests.swift
// MenuBarKitTests
//
// Pure logic tests for MBKMenuBarVisibilityLease.pinnedOptions(from:).
// Visibility behaviour requires on-device testing; see issue #2534.

import AppKit
import Testing
@testable import MenuBarKit

@MainActor
struct MBKMenuBarVisibilityLeaseTests {

    @Test func pinnedOptionsRemoveMenuBarHiding() {
        let original: NSApplication.PresentationOptions = [
            .autoHideMenuBar,
            .hideMenuBar,
            .autoHideDock
        ]

        let result = MBKMenuBarVisibilityLease.pinnedOptions(
            from: original
        )

        #expect(!result.contains(.autoHideMenuBar))
        #expect(!result.contains(.hideMenuBar))
        #expect(result.contains(.autoHideDock))
    }

    @Test func pinnedOptionsLeaveEmptyOptionsUnchanged() {
        let result = MBKMenuBarVisibilityLease.pinnedOptions(
            from: []
        )

        #expect(result == [])
    }
}
