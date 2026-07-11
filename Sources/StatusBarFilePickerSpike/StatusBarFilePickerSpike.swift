// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// HISTORY OF FAILED APPROACHES:
//
// ✗ .fileImporter: SwiftUI holds stale NSOpenPanel after outside-dismiss.
//   Binding flips true but panel never re-presents. Zombie panels accumulate.
//
// ✗ addChildWindow + runModal: MenuBarExtraWindow is NSNonactivatingPanel.
//   Child inherits non-activating — makeKeyAndOrderFront silently fails,
//   runModal() cancels on first click.
//
// ✗ addChildWindow + activate(ignoringOtherApps): Works but switches the
//   app to a regular foreground app (Dock icon appears, focus stolen). Wrong.
//
// ✓ SOLUTION: NSOpenPanel + orderFrontRegardless + begin(completionHandler:)
//
//   orderFrontRegardless() is the one NSWindow method that bypasses the
//   activating-panel gate entirely — it forces the window front without
//   requiring the app to be active or the parent to be activating.
//
//   begin(completionHandler:) is the async (non-blocking) sibling of
//   runModal(). It returns immediately and calls the handler on OK/Cancel,
//   so we never block the main thread and the menubar panel stays alive.
//
//   No addChildWindow. No activation policy change. No .fileImporter.
//   A fresh NSOpenPanel is created per invocation — no reuse/state issues.
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

            GroupBox("NSOpenPanel (orderFrontRegardless + async completion)") {
                Button("Pick File") {
                    log("► tapped")
                    FilePickerHelper.pickFile { url in
                        log("► completion url=\(url?.path ?? "nil")")
                        pickedURL = url
                    }
                }
                .frame(maxWidth: .infinity)
                Text("orderFrontRegardless bypasses non-activating gate.\nbegin(completionHandler:) is non-blocking — menubar stays open.\nFresh panel per tap — no reuse/state issues.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            GroupBox("Last picked") {
                Text(pickedURL?.lastPathComponent ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(pickedURL == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2).truncationMode(.middle)
                if pickedURL != nil {
                    Button("Clear") {
                        log("clear tapped")
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

// MARK: - File picker
//
// Creates a fresh NSOpenPanel per call. Uses orderFrontRegardless() to show
// it without needing the app to be active, then begin(completionHandler:)
// for a non-blocking async result. The menubar panel stays alive throughout.

@MainActor
enum FilePickerHelper {

    static func pickFile(
        canChooseDirectories: Bool = false,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        log("[picker] start")
        dumpWindows(label: "before-show")

        // Guard: don't open a second picker if one is already on screen.
        let alreadyOpen = NSApp.windows.contains {
            $0 is NSOpenPanel && $0.isVisible
        }
        if alreadyOpen {
            log("[picker] already open — skipping")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Place the panel at screen center.
        panel.center()
        log("[picker] panel centered to \(NSStringFromRect(panel.frame))")

        // orderFrontRegardless bypasses the NSNonactivatingPanel restriction
        // that makes makeKeyAndOrderFront silently fail. The panel appears
        // in front without stealing app-level activation.
        panel.orderFrontRegardless()
        log("[picker] orderFrontRegardless done — isVisible=\(panel.isVisible) isKey=\(panel.isKeyWindow)")

        dumpWindows(label: "after-orderFront")

        // begin(completionHandler:) is non-blocking: returns immediately,
        // fires the handler when the user picks or cancels.
        panel.begin { response in
            log("[picker] completion response=\(response == .OK ? "OK" : "Cancel") url=\(panel.url?.path ?? "nil")")
            dumpWindows(label: "after-completion")
            completion(response == .OK ? panel.url : nil)
        }

        log("[picker] begin(completionHandler:) registered — returning to caller")
    }
}
