// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// PROBLEM HISTORY:
//
// ✗ .fileImporter: SwiftUI owns panels, close() is no-op, zombies accumulate.
//
// ✗ addChildWindow + makeKeyAndOrderFront alone:
//   MenuBarExtraWindow is NSNonactivatingPanel. A child of a non-activating
//   panel cannot become key unless the app is active. makeKeyAndOrderFront
//   silently fails (isKeyWindow stays false). Any click on the panel is
//   treated as an outside-click and dismisses the menubar.
//
// ✓ SOLUTION:
//   Own the NSOpenPanel. addChildWindow to anchor it. Then briefly activate
//   the app (setActivationPolicy(.regular) + activate) so the panel CAN
//   become key, call makeKeyAndOrderFront, then immediately restore
//   .accessory on the next run-loop turn — before any user interaction.
//   This means the Dock icon appears for at most one frame.
//   begin(completionHandler:) keeps it non-blocking.
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
// Owns the NSOpenPanel lifecycle.
//
// show() sequence:
//   1. cancel() + removeChildWindow any existing panel.
//   2. Find MenuBarExtra window.
//   3. Fresh NSOpenPanel, addChildWindow to anchor in focus group.
//   4. Briefly setActivationPolicy(.regular) + activate so the non-activating
//      parent’s child can actually become key.
//   5. makeKeyAndOrderFront.
//   6. Restore .accessory on the NEXT run-loop turn (before any click lands).
//   7. begin(completionHandler:) — non-blocking.

@MainActor
final class FilePickerController {
    static let shared = FilePickerController()
    private var panel: NSOpenPanel?

    private var menuBarWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible }
    }

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        log("[picker] show")
        dumpWindows(label: "show-start")

        // Clean up any previous panel we own.
        if let old = panel {
            log("[picker] cancelling old panel isVisible=\(old.isVisible) isKey=\(old.isKeyWindow)")
            old.cancel(nil)
            if let parent = old.parent { parent.removeChildWindow(old) }
            panel = nil
        }

        guard let menuBarWindow else {
            log("[picker] ERROR: MenuBarExtra window not found")
            return
        }
        log("[picker] menuBarWindow frame=\(NSStringFromRect(menuBarWindow.frame))")

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.center()
        panel = p
        log("[picker] panel frame=\(NSStringFromRect(p.frame))")

        // Anchor in the MenuBarExtra focus group.
        menuBarWindow.addChildWindow(p, ordered: .above)
        log("[picker] addChildWindow — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")

        // A child of NSNonactivatingPanel can’t become key unless the app is
        // active. Activate briefly, make key, then restore .accessory on the
        // next run-loop so the Dock icon appears for at most one frame.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        log("[picker] activated — policy=regular")

        p.makeKeyAndOrderFront(nil)
        log("[picker] makeKeyAndOrderFront — isKey=\(p.isKeyWindow) isVisible=\(p.isVisible)")

        // Restore .accessory before the user can click anything.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            log("[picker] policy restored to .accessory")
        }

        dumpWindows(label: "after-show")

        p.begin { [weak self, weak p] response in
            guard let self, let p else { return }
            log("[picker] completion response=\(response == .OK ? "OK" : "Cancel") url=\(p.url?.path ?? "nil")")
            if let parent = p.parent { parent.removeChildWindow(p) }
            self.panel = nil
            dumpWindows(label: "after-completion")
            completion(response == .OK ? p.url : nil)
        }
        log("[picker] begin registered — returning")
    }
}
