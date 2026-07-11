// StatusBarFilePickerSpike.swift
//
// MenuBarExtra(.window) + NSOpenPanel via beginSheetModal.
//
// OUTSIDE-DISMISS STATE FIX:
// When the user clicks outside the MenuBarExtraWindow, the window hides
// but beginSheetModal's completion never fires — so activePanel stays
// non-nil and the next tap hits the "already open" guard.
//
// Fix: at the top of show(), synchronously check parentWindow.isVisible.
// If it's gone, the panel is stale — call panel.cancel(nil) right there.
// cancel() fires the beginSheetModal completion synchronously, which clears
// activePanel. Then we fall through and open fresh.
// No notifications. No KVO. No async delay.
//
// REQUIREMENTS: macOS 14+, Swift 6

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

@MainActor
final class FilePicker {
    static let shared = FilePicker()
    private var panel: NSOpenPanel?
    private weak var parentWindow: NSWindow?

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        // Synchronous stale-panel cleanup.
        // If the parent window is gone (outside-click dismissed it),
        // the beginSheetModal completion never fired. Cancel now so
        // the completion runs and clears self.panel before we continue.
        if let stale = panel, parentWindow?.isVisible != true {
            log("stale panel — cancelling")
            stale.cancel(nil)  // fires completion synchronously -> clears self.panel
        }

        guard panel == nil else { log("already open"); return }

        guard let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
        }) else { log("ERROR: no MenuBarExtraWindow"); return }

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        panel = p
        parentWindow = window
        log("opening sheet")

        p.beginSheetModal(for: window) { [weak self] response in
            log("done response=\(response == .OK ? "OK" : "Cancel")")
            self?.panel = nil
            self?.parentWindow = nil
            completion(response == .OK ? p.url : nil)
        }
    }
}
