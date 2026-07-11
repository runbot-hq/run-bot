// StatusBarFilePickerSpike.swift
//
// MenuBarExtra(.window) + own NSOpenPanel via beginSheetModal.
//
// OUTSIDE-DISMISS FIX:
// didChangeOcclusionStateNotification is throttled (fires seconds late).
// willCloseNotification doesn’t fire — MenuBarExtraWindow never “closes”,
// it just hides via orderOut.
// Fix: poll isVisible on the next run-loop after each tap. If the window
// is gone when the user taps again, cancel the stale panel immediately.
// This is O(1), synchronous, and requires no notifications.
//
// REQUIREMENTS: macOS 14+, Swift 6

import AppKit
import SwiftUI

private func log(_ msg: String, function: String = #function, line: Int = #line) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(function):\(line) \(msg)\n".data(using: .utf8)!)
}

@main
struct StatusBarFilePickerApp: App {
    init() { setvbuf(Foundation.stderr, nil, _IONBF, 0) }
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Picker Spike").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()
            Button("Pick File") {
                log("► tapped")
                FilePicker.shared.show { url in
                    pickedURL = url
                    log("► picked \(url?.lastPathComponent ?? "nil")")
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
//
// On each show() call:
//   1. If a panel is active, check if its parent window is still visible.
//      If not, cancel it immediately (synchronous cleanup).
//   2. Otherwise guard against double-open.
//   3. Show sheet on the current MenuBarExtraWindow.

@MainActor
final class FilePicker {
    static let shared = FilePicker()
    private var panel: NSOpenPanel?
    private weak var parentWindow: NSWindow?

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        // If we have an active panel but its window has hidden, cancel it now.
        if let existing = panel {
            if parentWindow?.isVisible != true {
                log("[picker] stale panel detected — cancelling")
                existing.cancel(nil)
                // cancel() fires completion synchronously in beginSheetModal,
                // which clears self.panel. Fall through to open fresh.
            } else {
                log("[picker] already open")
                return
            }
        }

        guard let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
        }) else { log("[picker] ERROR: no MenuBarExtraWindow"); return }

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        panel = p
        parentWindow = window
        log("[picker] opening sheet on \(type(of: window))")

        p.beginSheetModal(for: window) { [weak self] response in
            log("[picker] completion response=\(response == .OK ? "OK" : "Cancel")")
            self?.panel = nil
            self?.parentWindow = nil
            completion(response == .OK ? p.url : nil)
        }
    }
}
