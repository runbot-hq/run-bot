// StatusBarFilePickerSpike.swift
//
// MenuBarExtra(.window) + NSOpenPanel as a CHILD WINDOW (not a sheet).
//
// WHY NOT beginSheetModal:
//   MenuBarExtraWindow is NSNonactivatingPanel. Any click inside the sheet
//   is treated as an “outside click” and causes the parent to orderOut,
//   collapsing the sheet immediately.
//
// FIX:
//   Show NSOpenPanel as a standalone window via runModal() on a background
//   thread so the main thread stays live. Add it as a child window of
//   MenuBarExtraWindow BEFORE running so clicks inside don’t dismiss parent.
//   On outside-dismiss (parent hides), cancel the panel via KVO on isVisible.
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

@MainActor
final class FilePicker: NSObject {
    static let shared = FilePicker()
    private var panel: NSOpenPanel?
    private weak var parentWindow: NSWindow?
    private var visibilityObservation: NSKeyValueObservation?

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        // Stale panel: parent hid without our panel being cancelled yet.
        if let existing = panel, parentWindow?.isVisible != true {
            log("[picker] stale — aborting existing panel")
            teardown(existing)
        }
        guard panel == nil else { log("[picker] already open"); return }

        guard let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
        }) else { log("[picker] ERROR: no MenuBarExtraWindow"); return }

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.center()
        panel = p
        parentWindow = window

        // Add as child so clicks inside panel don’t trigger parent’s outside-click dismiss.
        window.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)
        log("[picker] opened as child window")

        // If parent hides (outside-click elsewhere), cancel the panel.
        visibilityObservation = window.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            if change.newValue == false {
                log("[picker] parent hidden — cancelling")
                DispatchQueue.main.async { [weak self] in
                    guard let self, let p = self.panel else { return }
                    self.teardown(p)
                    completion(nil)
                }
            }
        }

        // Handle OK / Cancel via notification (beginSheetModal not used).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: p,
            queue: .main
        ) { [weak self, weak p] _ in
            guard let self, let p else { return }
            // Only handle if parent is still visible (OK/Cancel click, not parent-hide).
            guard self.parentWindow?.isVisible == true else { return }
            log("[picker] willClose — response=\(p.url != nil ? "OK" : "Cancel")")
            let url = p.url
            self.teardown(p)
            completion(url)
        }
    }

    private func teardown(_ p: NSOpenPanel) {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: p)
        if let parent = p.parent { parent.removeChildWindow(p) }
        p.orderOut(nil)
        panel = nil
        parentWindow = nil
        log("[picker] teardown done")
    }
}
