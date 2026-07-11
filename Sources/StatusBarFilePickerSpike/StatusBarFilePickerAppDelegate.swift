// StatusBarFilePickerAppDelegate.swift
// StatusBarFilePickerSpike
import AppKit

/// Minimal app delegate that owns the status item and wires the file-picker menu action.
final class StatusBarFilePickerAppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var lastPickedURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "folder.badge.plus",
                                   accessibilityDescription: "Pick File")
        }
        let menu = NSMenu()
        let pick = NSMenuItem(
            title: "Pick File…",
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

    @objc private func pickFile() {
        lastPickedURL = FilePickerHelper.pickFile()
    }

    @objc private func showLastPicked() {
        let alert = NSAlert()
        alert.messageText = "Last Picked File"
        alert.informativeText = lastPickedURL?.path ?? "(none yet — pick a file first)"
        alert.runModal()
    }
}
