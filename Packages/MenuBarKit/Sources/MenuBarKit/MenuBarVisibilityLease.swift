// MenuBarVisibilityLease.swift
// MenuBarKit
//
// Scoped menu-bar visibility lease for MBKPanelController.
//
// Design:
//   - Snapshots NSApp.presentationOptions on acquire; restores exactly on release.
//   - Defers the actual setMenuBarVisible call to a separate run-loop turn so
//     AppKit has committed activation before the menu-bar refresh runs.
//   - Uses a false→true visibility toggle (documented LSUIElement workaround)
//     to force AppKit to commit the change when a single true is ignored.
//   - KVO-observes currentSystemPresentationOptions to reassert if AppKit
//     re-applies auto-hide after activation or navigation.
//   - A generation counter cancels any in-flight deferred refresh after release.

import AppKit

/// Scoped menu-bar visibility lease for `MBKPanelController`.
///
/// Acquire once when the panel opens; release once when it closes.
/// Every open path must funnel through a corresponding release.
@MainActor
final class MBKMenuBarVisibilityLease {

    // MARK: - Stored state

    /// Presentation options captured when the lease was acquired.
    /// `nil` means there is no active lease.
    private var savedOptions: NSApplication.PresentationOptions?

    /// Incremented on every release to cancel in-flight deferred refreshes.
    private var refreshGeneration = 0

    /// True while a deferred refresh Task is queued, to coalesce burst requests.
    private var refreshScheduled = false

    /// KVO token for NSApp.currentSystemPresentationOptions.
    private var presentationObservation: NSKeyValueObservation?

    // MARK: - Public interface

    /// Whether this lease currently owns a presentation-options snapshot.
    var isActive: Bool {
        savedOptions != nil
    }

    /// Returns presentation options with menu-bar hiding removed while
    /// preserving every unrelated option.
    nonisolated static func pinnedOptions(
        from options: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var result = options
        result.remove(.autoHideMenuBar)
        result.remove(.hideMenuBar)
        return result
    }

    // MARK: - Acquire

    /// Acquires the lease once. Repeated acquisition is an idempotent no-op.
    func acquire() {
        guard savedOptions == nil else {
            mbkLog("MenuBarVisibilityLease", "acquire -- already active")
            return
        }

        let original = NSApp.presentationOptions
        savedOptions = original
        NSApp.presentationOptions = Self.pinnedOptions(from: original)

        startPresentationObservation()
        requestVisibilityRefresh(reason: "acquire")

        mbkLog(
            "MenuBarVisibilityLease",
            """
            acquire -- \
            originalOptions=\(original.rawValue) \
            pinnedOptions=\(NSApp.presentationOptions.rawValue)
            """
        )
    }

    // MARK: - Deferred refresh

    /// Schedules a visibility refresh for the next main-actor turn.
    /// Coalesces burst requests: multiple calls within one turn produce one refresh.
    func requestVisibilityRefresh(reason: String) {
        guard isActive, !refreshScheduled else { return }

        refreshScheduled = true
        let generation = refreshGeneration

        Task { @MainActor [weak self] in
            await Task.yield()

            guard let self,
                  self.isActive,
                  self.refreshGeneration == generation
            else { return }

            self.refreshScheduled = false

            // Reassert pinned options after activation/key-window changes.
            if let saved = self.savedOptions {
                NSApp.presentationOptions = Self.pinnedOptions(from: saved)
            }

            // false→true toggle forces AppKit to commit when a single `true` is ignored.
            // This is the documented LSUIElement workaround.
            NSMenu.setMenuBarVisible(false)
            NSMenu.setMenuBarVisible(true)

            await Task.yield()

            guard self.isActive,
                  self.refreshGeneration == generation
            else { return }

            mbkLog(
                "MenuBarVisibilityLease",
                """
                refresh -- \
                reason=\(reason) \
                appActive=\(NSApp.isActive) \
                requestedOptions=\(NSApp.presentationOptions.rawValue) \
                effectiveOptions=\(NSApp.currentSystemPresentationOptions.rawValue) \
                menuBarVisible=\(NSMenu.menuBarVisible())
                """
            )
        }
    }

    // MARK: - KVO observer

    private func startPresentationObservation() {
        presentationObservation?.invalidate()

        presentationObservation = NSApp.observe(
            \.currentSystemPresentationOptions,
            options: [.new]
        ) { [weak self] _, change in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }

                let effective = change.newValue
                    ?? NSApp.currentSystemPresentationOptions

                mbkLog(
                    "MenuBarVisibilityLease",
                    "effective options changed -- \(effective.rawValue)"
                )

                if effective.contains(.autoHideMenuBar)
                    || effective.contains(.hideMenuBar) {
                    self.requestVisibilityRefresh(
                        reason: "effective-options-changed"
                    )
                }
            }
        }
    }

    // MARK: - Release

    /// Restores the exact options captured by `acquire()`.
    ///
    /// Cancels in-flight deferred refreshes and KVO observation before
    /// restoring options. Does not call `NSMenu.setMenuBarVisible(false)`.
    func release() {
        guard let original = savedOptions else {
            mbkLog("MenuBarVisibilityLease", "release -- inactive")
            return
        }

        // Cancel any in-flight deferred refresh.
        refreshGeneration += 1
        refreshScheduled = false

        presentationObservation?.invalidate()
        presentationObservation = nil

        savedOptions = nil
        NSApp.presentationOptions = original

        mbkLog(
            "MenuBarVisibilityLease",
            """
            release -- \
            restoredOptions=\(original.rawValue) \
            effectiveOptions=\(NSApp.currentSystemPresentationOptions.rawValue) \
            menuBarVisible=\(NSMenu.menuBarVisible())
            """
        )
    }
}
