// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// DEBUG BUILD — heavy logging enabled throughout.
//
// FINDINGS FROM PREVIOUS ATTEMPTS:
//
// A) .fileImporter reuses the same NSOpenPanel instance — after outside-dismiss
//    the old panel stays alive (isVisible=false, isKey=false). The anchor search
//    relies on isKeyWindow=true to find it, which never fires on the stale instance.
//    Each button tap leaks another invisible NSOpenPanel into NSApp.windows.
//
// B) addChildWindow on a NSNonactivatingPanel (MenuBarExtraWindow styleMask=32896)
//    makes the child inherit non-activating behaviour. makeKeyAndOrderFront silently
//    fails (isKeyWindow stays false). runModal() returns .cancel almost immediately
//    because the panel can't receive clicks.
//
// ROOT FIX:
//
// Use NSOpenPanel.beginSheetModal(for: menuBarWindow) instead of addChildWindow.
// Sheet-modal attaches the panel to the window as an AppKit sheet, which:
//   • does NOT rely on the child-window focus group
//   • does NOT require the parent to be activating
//   • keeps the MenuBarExtra window alive (macOS treats its own sheet as in-scope)
//   • works reliably on repeated invocations
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

            GroupBox("NSOpenPanel via beginSheetModal") {
                Button("Pick File") {
                    log("► button tapped")
                    FilePickerHelper.pickFile { url in
                        log("► completion url=\(url?.path ?? "nil")")
                        pickedURL = url
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Sheet attaches to MenuBarExtra window. Panel stays open on click. Repeated invocations work.")
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

// MARK: - Window dump helper

@MainActor
private func dumpWindows(label: String) {
    let wins = NSApp.windows
    log("[windows:\(label)] total=\(wins.count)")
    for (i, w) in wins.enumerated() {
        log("  [\(i)] \(type(of: w)) isKey=\(w.isKeyWindow) isVisible=\(w.isVisible) styleMask=\(w.styleMask.rawValue) frame=\(NSStringFromRect(w.frame)) parent=\(w.parent == nil ? "nil" : String(describing: type(of: w.parent!))) children=\(w.childWindows?.count ?? 0) sheets=\(w.sheets.count)")
    }
}

// Key for objc_setAssociatedObject. Must be `let` so Swift 6 sees it as
// immutable shared state (the address never changes; the value is irrelevant).
private let delegateKey: UInt8 = 0

// MARK: - NSOpenPanel helper
//
// Uses beginSheetModal(for:) to attach the picker as an AppKit sheet on
// the MenuBarExtra window. This is the correct primitive: sheets don't
// depend on the parent's activating policy and survive repeated invocations.

@MainActor
enum FilePickerHelper {

    static func pickFile(
        canChooseDirectories: Bool = false,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        log("[picker] pickFile start")
        dumpWindows(label: "before-show")

        guard let menuBarWindow = NSApp.windows.first(where: {
            // MenuBarExtraWindow styleMask=32896 (NSPanel | nonactivatingPanel)
            $0.styleMask.rawValue == 32896 && $0.isVisible
        }) else {
            log("[picker] ERROR: MenuBarExtra window not found — falling back to runModal")
            completion(runModalFallback(canChooseDirectories: canChooseDirectories))
            return
        }
        log("[picker] menuBarWindow=\(type(of: menuBarWindow)) frame=\(NSStringFromRect(menuBarWindow.frame)) sheets=\(menuBarWindow.sheets.count)")

        // If a sheet is already attached (e.g. previous panel not yet dismissed),
        // close it before opening a new one.
        if !menuBarWindow.sheets.isEmpty {
            log("[picker] WARNING: existing sheet found — ending it before opening new one")
            menuBarWindow.sheets.forEach { menuBarWindow.endSheet($0) }
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let delegate = PanelDelegate()
        panel.delegate = delegate
        // Retain the delegate for the lifetime of the panel via associated object.
        // withUnsafePointer gives us a stable pointer to the let constant.
        withUnsafePointer(to: delegateKey) {
            objc_setAssociatedObject(panel, $0, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        log("[picker] calling beginSheetModal")
        panel.beginSheetModal(for: menuBarWindow) { response in
            log("[picker] sheet completion response=\(response == .OK ? "OK" : "Cancel") url=\(panel.url?.path ?? "nil")")
            dumpWindows(label: "after-sheet-close")
            completion(response == .OK ? panel.url : nil)
        }

        dumpWindows(label: "after-beginSheetModal")
        log("[picker] panel isVisible=\(panel.isVisible) isKey=\(panel.isKeyWindow) frame=\(NSStringFromRect(panel.frame))")
    }

    private static func runModalFallback(canChooseDirectories: Bool) -> URL? {
        log("[picker-fallback] activation-dance start")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        let result = panel.runModal()
        log("[picker-fallback] result=\(result == .OK ? "OK" : "Cancel")")
        NSApp.setActivationPolicy(.accessory)
        return result == .OK ? panel.url : nil
    }
}

// MARK: - Panel delegate (logging)

private final class PanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panelSelectionDidChange(_ sender: Any?) {
        log("[delegate] panelSelectionDidChange")
    }
    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        log("[delegate] didChangeToDirectoryURL: \(url?.path ?? "nil")")
    }
    func panel(_ sender: Any, validate url: URL) throws {
        log("[delegate] validate url=\(url.path)")
    }
    func panel(_ sender: Any, willExpand expanding: Bool) {
        log("[delegate] willExpand expanding=\(expanding)")
    }
}
