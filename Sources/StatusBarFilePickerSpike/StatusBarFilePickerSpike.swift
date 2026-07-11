// StatusBarFilePickerSpike.swift
//
// MenuBarExtra(.window) for the SwiftUI popover.
// Own NSOpenPanel shown as a sheet via beginSheetModal(for:).
// No .fileImporter. No window hunting. No state tricks.
//
// REQUIREMENTS: macOS 14+, Swift 6

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func log(_ msg: String, function: String = #function, line: Int = #line) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(function):\(line) \(msg)\n".data(using: .utf8)!)
}

// MARK: - Entry point

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

// MARK: - Content

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
//
// Finds the MenuBarExtraWindow and shows NSOpenPanel as a sheet.
// beginSheetModal is non-blocking and AppKit handles all focus/dismissal.
// Guard against double-tap: if a sheet is already attached, do nothing.

@MainActor
private var activePanel: NSOpenPanel?

@MainActor
func showFilePicker(completion: @escaping @MainActor (URL?) -> Void) {
    guard activePanel == nil else {
        log("[picker] already open, ignoring")
        return
    }
    guard let window = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
    }) else {
        log("[picker] ERROR: MenuBarExtraWindow not found")
        return
    }
    log("[picker] opening sheet on \(type(of: window))")

    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    activePanel = panel

    panel.beginSheetModal(for: window) { response in
        log("[picker] sheet done response=\(response == .OK ? "OK" : "Cancel")")
        activePanel = nil
        completion(response == .OK ? panel.url : nil)
    }
}
