// StatusBarFilePickerSpike.swift
//
// MenuBarExtraWindow is a .nonactivatingPanel — AppKit cannot attach sheets
// to it. begin() works but the panel appears behind the popover.
//
// Fix: spin up a minimal, borderless, 1×1 NSWindow (real activating window),
// make it key, attach the sheet to it. The host window is invisible to the
// user but gives AppKit the keyWindow it needs to front the sheet properly.
// Close the host when the sheet completes.
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
    private var hostWindow: NSWindow?

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        // Stale: panel exists but sheet was torn down externally.
        if let p = panel, !p.isVisible, p.sheetParent == nil {
            log("stale panel — clearing")
            panel = nil
            hostWindow?.close()
            hostWindow = nil
        }

        guard panel == nil else { log("already open"); return }

        // Invisible 1×1 activating window — gives AppKit a keyWindow to
        // attach the sheet to so it appears in front of everything.
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.backgroundColor = .clear
        host.isOpaque = false
        host.level = .floating
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hostWindow = host
        log("host window created, isKey=\(host.isKeyWindow)")

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        panel = p
        log("opening sheet on host window")

        p.beginSheetModal(for: host) { [weak self] response in
            log("done response=\(response == .OK ? "OK" : "Cancel")")
            self?.panel = nil
            self?.hostWindow?.close()
            self?.hostWindow = nil
            completion(response == .OK ? p.url : nil)
        }
    }
}
