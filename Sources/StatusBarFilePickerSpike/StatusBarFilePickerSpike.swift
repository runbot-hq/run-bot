// StatusBarFilePickerSpike.swift
//
// MenuBarExtra(.window) + own NSOpenPanel via beginSheetModal.
// When the MenuBarExtraWindow hides (outside-click), the sheet is
// orphaned and beginSheetModal’s completion never fires.
// Fix: observe NSWindow.didChangeOcclusionStateNotification on the
// parent window; when it becomes hidden, cancel the panel explicitly
// so the completion fires and activePanel resets.
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
                showFilePicker { url in
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

// MARK: - File picker

@MainActor private var activePanel: NSOpenPanel?
@MainActor private var occlusionObserver: (any NSObjectProtocol)?

@MainActor
func showFilePicker(completion: @escaping @MainActor (URL?) -> Void) {
    guard activePanel == nil else { log("[picker] already open"); return }

    guard let window = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
    }) else { log("[picker] ERROR: no MenuBarExtraWindow"); return }

    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    activePanel = panel
    log("[picker] opening sheet")

    // When the MenuBarExtraWindow disappears (outside-click), the sheet
    // is orphaned and completion never fires. Cancel panel explicitly.
    occlusionObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
    ) { [weak window, weak panel] _ in
        guard let window, let panel else { return }
        if !window.isVisible && activePanel != nil {
            log("[picker] parent hidden — cancelling panel")
            panel.cancel(nil)
        }
    }

    panel.beginSheetModal(for: window) { response in
        log("[picker] completion response=\(response == .OK ? "OK" : "Cancel")")
        if let obs = occlusionObserver {
            NotificationCenter.default.removeObserver(obs)
            occlusionObserver = nil
        }
        activePanel = nil
        completion(response == .OK ? panel.url : nil)
    }
}
