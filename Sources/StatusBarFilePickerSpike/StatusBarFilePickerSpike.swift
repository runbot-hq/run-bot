// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// ROOT CAUSE OF ALL PREVIOUS FAILURES:
//   .fileImporter keeps the NSOpenPanel alive after outside-dismiss.
//   .close() is a no-op on SwiftUI-owned panels. Every tap leaks another
//   invisible zombie. The anchor search (isKeyWindow==true) always fails
//   because SwiftUI never makes the reused panel key.
//
// SOLUTION:
//   Own the NSOpenPanel ourselves. Keep a single optional instance.
//   On each tap: cancel() the old one (if any), create a fresh panel,
//   call addChildWindow to anchor it, then makeKeyAndOrderFront.
//   Use begin(completionHandler:) (non-blocking async) so the menubar
//   panel stays open throughout.
//
//   No activation policy change. No runModal(). No .fileImporter.
//   The panel is always fresh — no reuse, no zombie, no state issues.
//
// REQUIREMENTS: macOS 26, Swift 6
// DEPENDENCIES: none

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Logging

private func log(_ msg: String, file: String = #fileID, line: Int = #line, function: String = #function) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(function):\(line) \(msg)")
}

// MARK: - Entry point

@main
struct StatusBarFilePickerApp: App {
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
            Text("File Picker Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Button("Pick File") {
                log("► tapped")
                FilePickerController.shared.show { url in
                    log("► completion url=\(url?.path ?? "nil")")
                    pickedURL = url
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
                if pickedURL != nil {
                    Button("Clear") {
                        log("clear")
                        pickedURL = nil
                    }.font(.caption)
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

// MARK: - Window dump

@MainActor
private func dumpWindows(label: String) {
    let wins = NSApp.windows
    log("[windows:\(label)] total=\(wins.count)")
    for (i, w) in wins.enumerated() {
        log("  [\(i)] \(type(of: w)) isKey=\(w.isKeyWindow) isVisible=\(w.isVisible) styleMask=\(w.styleMask.rawValue) frame=\(NSStringFromRect(w.frame)) parent=\(w.parent == nil ? "nil" : "set") children=\(w.childWindows?.count ?? 0)")
    }
}

// MARK: - FilePickerController
//
// Owns a single NSOpenPanel. On each show() call:
//   1. cancel() + removeChildWindow on any existing panel (clean slate).
//   2. Find the MenuBarExtra window by styleMask.
//   3. Create a fresh NSOpenPanel.
//   4. addChildWindow — puts it in the MenuBarExtra focus group so clicks
//      inside don’t count as outside-clicks.
//   5. makeKeyAndOrderFront — brings it to front.
//   6. begin(completionHandler:) — non-blocking, fires on OK/Cancel.

@MainActor
final class FilePickerController {
    static let shared = FilePickerController()
    private var panel: NSOpenPanel?
    private var menuBarWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible }
    }

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        log("[picker] show called")
        dumpWindows(label: "show-start")

        // Cancel and detach any existing panel.
        if let old = panel {
            log("[picker] cancelling existing panel isVisible=\(old.isVisible)")
            old.cancel(nil)
            if let parent = old.parent { parent.removeChildWindow(old) }
            panel = nil
        }

        guard let menuBarWindow else {
            log("[picker] ERROR: MenuBarExtra window not found")
            return
        }
        log("[picker] menuBarWindow=\(NSStringFromRect(menuBarWindow.frame))")

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.center()
        panel = p

        log("[picker] panel created, frame=\(NSStringFromRect(p.frame))")

        // Anchor: put the panel in the MenuBarExtra focus group.
        menuBarWindow.addChildWindow(p, ordered: .above)
        log("[picker] addChildWindow done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")

        // Bring to front.
        p.makeKeyAndOrderFront(nil)
        log("[picker] makeKeyAndOrderFront — isKey=\(p.isKeyWindow) isVisible=\(p.isVisible)")

        dumpWindows(label: "after-show")

        // Non-blocking: returns immediately, fires completion on OK/Cancel.
        p.begin { [weak self, weak p] response in
            guard let self, let p else { return }
            log("[picker] completion response=\(response == .OK ? "OK" : "Cancel") url=\(p.url?.path ?? "nil")")
            if let parent = p.parent { parent.removeChildWindow(p) }
            self.panel = nil
            dumpWindows(label: "after-completion")
            completion(response == .OK ? p.url : nil)
        }

        log("[picker] begin(completionHandler:) registered")
    }
}
