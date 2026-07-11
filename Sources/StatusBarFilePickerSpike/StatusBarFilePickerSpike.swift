// StatusBarFilePickerSpike.swift
//
// NSStatusItem + NSPopover with behavior = .applicationDefined.
// We control close: keep popover open while NSOpenPanel is on screen,
// close it on outside-click only when no panel is active.
//
// REQUIREMENTS: macOS 14+, Swift 6

import AppKit
import SwiftUI

private func log(_ msg: String, function: String = #function, line: Int = #line) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(function):\(line) \(msg)\n".data(using: .utf8)!)
}

// MARK: - App delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(Foundation.stderr, nil, _IONBF, 0)
        log("launch")

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        let contentView = ContentView()
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.contentSize = NSSize(width: 320, height: 280)
        popover.behavior = .applicationDefined
        popover.animates = true

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if FilePicker.shared.isOpen {
                log("[monitor] outside click ignored - panel open")
            } else {
                log("[monitor] outside click - closing popover")
                self.popover.performClose(nil)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            if !FilePicker.shared.isOpen { popover.performClose(nil) }
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// MARK: - Content view

struct ContentView: View {
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Picker Spike").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()
            Button("Pick File") {
                log("tapped")
                FilePicker.shared.show { url in
                    pickedURL = url
                    log("picked \(url?.lastPathComponent ?? "nil")")
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            GroupBox("Last picked") {
                Text(pickedURL?.lastPathComponent ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(pickedURL == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2).truncationMode(.middle)
                if pickedURL != nil { Button("Clear") { pickedURL = nil }.font(.caption) }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }.foregroundStyle(.red).frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 280)
    }
}

// MARK: - FilePicker

@MainActor
final class FilePicker {
    static let shared = FilePicker()
    private(set) var isOpen = false
    private var panel: NSOpenPanel?

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        guard !isOpen else { log("[picker] already open"); return }

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        panel = p
        isOpen = true
        log("[picker] opening")

        // Activate the app so the panel comes to front.
        // .accessory apps are not normally active, so the panel would
        // appear behind other windows without this.
        NSApp.activate(ignoringOtherApps: true)

        p.begin { [weak self] response in
            log("[picker] done response=\(response == .OK ? "OK" : "Cancel")")
            self?.panel = nil
            self?.isOpen = false
            // Return to accessory policy so we don't steal focus permanently.
            NSApp.setActivationPolicy(.accessory)
            completion(response == .OK ? p.url : nil)
        }

        // Ensure the panel is frontmost after begin() schedules it.
        DispatchQueue.main.async {
            p.orderFrontRegardless()
        }
    }
}
