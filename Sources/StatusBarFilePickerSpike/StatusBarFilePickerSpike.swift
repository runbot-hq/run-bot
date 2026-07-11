// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// Manual NSStatusBar + NSPanel + NSOpenPanel as sheet.
// Outside-click dismissal via NSEvent.addGlobalMonitorForEvents.
// While the file picker sheet is open, outside clicks are ignored so
// the popover stays alive for the sheet.
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
    private var eventMonitor: Any?
    private var sheetIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

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
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        positionPopover()
        popoverWindow.makeKeyAndOrderFront(nil)
        // Global monitor: fires for clicks in OTHER apps / outside our window.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.sheetIsOpen else { return }
            self.closePopover()
        }
    }

    private func closePopover() {
        popoverWindow.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
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
        sheetIsOpen = true
        panel.beginSheetModal(for: popoverWindow) { [weak self] response in
            self?.sheetIsOpen = false
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
