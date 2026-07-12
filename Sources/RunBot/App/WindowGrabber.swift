// WindowGrabber.swift
// RunBot
//
// DELETED in PR-A (step 4): replaced by `mbkOpenFilePicker(target:overlayGate:completion:)`
// from MenuBarKit. The sole call site was `AddRunnerSheet.swift`.
//
// This file is intentionally left as a tombstone comment only.
// It will be removed in a follow-up cleanup commit once the branch is merged
// and confirmed stable. Keeping it avoids a "file deleted" git-blame gap
// while the PR is in review.
//
// ORIGINAL PURPOSE (for graveyard reference):
//   Exposed the hosting NSWindow to SwiftUI views so NSOpenPanel.beginSheetModal
//   could attach the picker to the correct window. Now superseded by
//   MBKFilePicker, which resolves the correct window internally via
//   NSApp.windows predicate matching.
//
// See: docs/graveyard.md, PR-A (#2041), FilePicker.swift (MenuBarKit)
