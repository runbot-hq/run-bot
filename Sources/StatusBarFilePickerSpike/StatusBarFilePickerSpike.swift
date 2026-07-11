// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// PURPOSE:
// Verifies that NSOpenPanel reliably appears in front of other windows
// when triggered from a menubar-only (.accessory-policy) app on macOS.
//
// ROOT CAUSE OF THE PROBLEM:
// Menubar apps run with NSApplication.ActivationPolicy.accessory.
// macOS does not consider them "foreground" apps, so NSOpenPanel.runModal()
// renders behind other windows without explicit app activation.
//
// THE FIX (activation-policy dance):
//   NSApp.setActivationPolicy(.regular)
//   NSApp.activate(ignoringOtherApps: true)
//   let result = panel.runModal()
//   NSApp.setActivationPolicy(.accessory)
//
// HOW TO RUN:
//   swift run StatusBarFilePickerSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears (folder.badge.plus).
//   2. Click icon → menu appears.
//   3. Click "Pick File…" → NSOpenPanel appears IN FRONT of all other windows.
//   4. Cancel → panel disappears, no URL stored. "Show Last Picked" shows "(none)".
//   5. OK → "Show Last Picked" shows the correct file path.
//   6. Dock icon appears briefly while panel is open, disappears on close.
//   7. Repeat 5x — no crashes, no stuck Dock icon.
//
// REQUIREMENTS: macOS 26, Swift 6
// DEPENDENCIES: none (zero RunBot deps)

import AppKit

// MARK: - Entry point

let delegate = StatusBarFilePickerAppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

// MARK: - App delegate

final class StatusBarFilePickerAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    private var statusItem: NSStatusItem?
    private var lastPickedURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "folder.badge.plus",
                accessibilityDescription: "Pick File"
            )
        }

        let menu = NSMenu()

        let pick = NSMenuItem(
            title: "Pick File\u{2026}",
            action: #selector(pickFile),
            keyEquivalent: "o"
        )
        pick.target = self
        menu.addItem(pick)

        let show = NSMenuItem(
            title: "Show Last Picked",
            action: #selector(showLastPicked),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func pickFile() {
        lastPickedURL = FilePickerHelper.pickFile()
    }

    @objc private func showLastPicked() {
        let alert = NSAlert()
        alert.messageText = "Last Picked File"
        alert.informativeText = lastPickedURL?.path ?? "(none — pick a file first)"
        alert.runModal()
    }
}

// MARK: - File picker helper

enum FilePickerHelper {

    /// Presents an `NSOpenPanel` and returns the selected URL, or `nil` if cancelled.
    ///
    /// ## Activation dance
    /// Menubar apps run with `.accessory` activation policy. Without temporarily
    /// switching to `.regular`, the open panel often appears behind other windows.
    ///
    /// - Parameters:
    ///   - allowedTypes: UTType file extensions to restrict (empty = all types).
    ///   - canChooseDirectories: Whether the user can pick directories.
    /// - Returns: The selected `URL`, or `nil` if cancelled.
    static func pickFile(
        allowedTypes: [String] = [],
        canChooseDirectories: Bool = false
    ) -> URL? {
        // 1. Promote to .regular so the panel can become key and come to front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !allowedTypes.isEmpty {
            // NOTE: allowedFileTypes is deprecated on macOS 12+.
            // Swap for allowedContentTypes: [UTType] when integrating into the main target.
            panel.allowedFileTypes = allowedTypes
        }

        let result = panel.runModal()

        // 2. Restore .accessory so the Dock icon disappears again.
        NSApp.setActivationPolicy(.accessory)

        return result == .OK ? panel.url : nil
    }
}
