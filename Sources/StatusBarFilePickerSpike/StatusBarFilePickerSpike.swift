// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// WHY WE DROPPED MenuBarExtra:
//   MenuBarExtraWindow is NSNonactivatingPanel. Child windows of a
//   non-activating panel can’t receive key events without hacks (activation
//   policy dance, ObjC selector trampolines, etc). Every workaround either
//   crashes under Swift 6 strict concurrency or causes a visible Dock bounce.
//
// SOLUTION: manual NSStatusBar + borderless NSWindow.
//   A plain NSWindow has no activation constraints. NSOpenPanel works
//   as a normal child window with no tricks required.
//
//   • NSStatusItem holds the menu bar icon.
//   • Clicking the icon toggles a borderless NSWindow (the “panel”).
//   • The window uses NSPanel subclass with .nonactivatingPanel so clicking
//     it doesn’t steal focus from other apps — same UX as MenuBarExtra.
//   • NSOpenPanel is shown with beginSheetModal(for:) which attaches it as
//     a sheet to our window — no child window wrangling needed at all.
//
// REQUIREMENTS: macOS 14+, Swift 6
// DEPENDENCIES: none

import AppKit
import SwiftUI

// MARK: - Entry point

@main
struct StatusBarFilePickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popoverWindow: NSPanel!
    private var hostingView: NSHostingView<ContentView>!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Status bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        // Borderless non-activating panel — same feel as MenuBarExtra(.window)
        let size = CGSize(width: 320, height: 280)
        popoverWindow = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        popoverWindow.isFloatingPanel = true
        popoverWindow.becomesKeyOnlyIfNeeded = true
        popoverWindow.isMovable = false
        popoverWindow.backgroundColor = .windowBackgroundColor
        popoverWindow.hasShadow = true

        let contentView = ContentView(pickFile: { [weak self] completion in
            self?.showFilePicker(completion: completion)
        })
        hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        popoverWindow.contentView = hostingView
    }

    @objc private func togglePopover() {
        if popoverWindow.isVisible {
            popoverWindow.orderOut(nil)
        } else {
            positionPopover()
            popoverWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func positionPopover() {
        guard let button = statusItem.button,
              let screen = button.window?.screen ?? NSScreen.main else { return }
        let buttonRect = button.window!.convertToScreen(button.frame)
        let x = buttonRect.midX - popoverWindow.frame.width / 2
        let y = buttonRect.minY - popoverWindow.frame.height - 4
        let clamped = max(screen.visibleFrame.minX, min(x, screen.visibleFrame.maxX - popoverWindow.frame.width))
        popoverWindow.setFrameOrigin(NSPoint(x: clamped, y: y))
    }

    private func showFilePicker(completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Sheet attaches to our window — no child window tricks, no activation
        panel.beginSheetModal(for: popoverWindow) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

// MARK: - Content

struct ContentView: View {
    let pickFile: (@escaping @MainActor (URL?) -> Void) -> Void
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Picker Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Button("Pick File") {
                pickFile { url in pickedURL = url }
            }
            .frame(maxWidth: .infinity)

            Divider()

            GroupBox("Last picked") {
                Text(pickedURL?.lastPathComponent ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(pickedURL == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2).truncationMode(.middle)
                if pickedURL != nil {
                    Button("Clear") { pickedURL = nil }.font(.caption)
                }
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.red).frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 280)
    }
}
