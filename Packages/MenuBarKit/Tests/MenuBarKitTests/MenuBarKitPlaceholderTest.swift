// MenuBarKitPlaceholderTest.swift
// MenuBarKitTests
//
// Single placeholder test required by `swift test` when no test target
// is declared in Package.swift. With no test target, SPM 6.2 exits with
// code 1 ("no tests found"). This file is deleted when real tests exist.
//
// Long-term: MenuBarKit is an AppKit-adjacent package — its behaviour
// depends on a live NSApplication, real NSScreen geometry, and macOS
// compositor state. Correctness is validated by device testing, not
// unit tests. See README.md → Testing section.
import Testing

/// Placeholder: see file header.
@Test("placeholder — delete when MenuBarKit has real tests")
func placeholder() {}