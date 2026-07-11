// StatusBarFilePickerSpike.swift
//
// MenuBarExtra(.window) uses a NSPanel with .nonactivatingPanel style mask.
// AppKit silently refuses to attach sheets to non-activating panels, so
// beginSheetModal never visually appears after the first outside-dismiss.
//
// Fix: activate the app, then run NSOpenPanel modally with begin().
// The completion clears state exactly as before.
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

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        // Stale: panel exists but is no longer visible and has no sheet parent.
        if let p = panel, !p.isVisible, p.sheetParent == nil {
            log("stale panel — clearing")
            p.cancel(nil)
            panel = nil
        }

        guard panel == nil else { log("already open"); return }

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        panel = p
        log("opening panel")

        // Activate so the panel becomes key and actually appears.
        // ignoringOtherApps:true is required from a background/accessory app.
        NSApp.activate(ignoringOtherApps: true)

        p.begin { [weak self] response in
            log("done response=\(response == .OK ? "OK" : "Cancel")")
            self?.panel = nil
            completion(response == .OK ? p.url : nil)
        }
    }
}
