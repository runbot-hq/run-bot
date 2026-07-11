// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// DEBUG BUILD — heavy logging enabled throughout.
//
// TWO APPROACHES UNDER TEST:
//
// A) .fileImporter + anchor
//    Problem was: SwiftUI reuses the NSOpenPanel instance across calls.
//    After an outside-dismiss it stays alive (isVisible=false, isKey=false,
//    parent=nil). We now look for an existing invisible NSOpenPanel first
//    and call orderFront on it rather than waiting for a new key window.
//
// B) NSOpenPanel + addChildWindow
//    Problem was: MenuBarExtraWindow is a NSNonactivatingPanel (styleMask=32896).
//    Child windows inherit non-activating behaviour — makeKeyAndOrderFront
//    silently fails (isKeyWindow stays false), runModal() immediately cancels.
//    Fix: call NSApp.activate(ignoringOtherApps: true) AFTER addChildWindow
//    but BEFORE makeKeyAndOrderFront. This makes the app active so the panel
//    can actually receive events. Restore .accessory policy after runModal.
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
    @State private var isImporting = false
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Picker Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // Approach A: .fileImporter
            // Reuse fix: force false→true transition every tap so SwiftUI
            // re-presents the (possibly reused) panel.
            GroupBox("Approach A — .fileImporter") {
                Button("Pick File (A)") {
                    log("A ► tapped, isImporting=\(isImporting)")
                    isImporting = false
                    DispatchQueue.main.async {
                        log("A ► async: setting isImporting=true")
                        isImporting = true
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Approach B: NSOpenPanel + addChildWindow + activate
            GroupBox("Approach B — NSOpenPanel") {
                Button("Pick File (B)") {
                    log("B ► tapped")
                    pickedURL = FilePickerHelper.pickFile()
                    log("B ► returned: \(pickedURL?.path ?? "nil")")
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            GroupBox("Last picked") {
                Text(pickedURL?.lastPathComponent ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(pickedURL == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2).truncationMode(.middle)
                if pickedURL != nil {
                    Button("Clear") { pickedURL = nil }.font(.caption)
                }
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.red).frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 280)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                log("A ► success url=\(urls.first?.path ?? "nil")")
                pickedURL = urls.first
            case .failure(let err):
                log("A ► failure err=\(err)")
            }
        }
        .onChange(of: isImporting) { old, new in
            log("A ► isImporting \(old)→\(new)")
            dumpWindows(label: "isImporting-\(new)")
        }
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

// MARK: - Approach B helper
//
// Key insight: MenuBarExtraWindow is NSNonactivatingPanel (styleMask=32896).
// addChildWindow makes the child inherit non-activating — it cannot become key.
// Solution: activate the app explicitly after anchoring, before makeKeyAndOrderFront.
// Restore .accessory after runModal so the menubar app goes back to normal.

@MainActor
enum FilePickerHelper {

    static func pickFile(canChooseDirectories: Bool = false) -> URL? {
        log("[B] start")
        dumpWindows(label: "B-start")

        guard let menuBarWindow = NSApp.windows.first(where: {
            $0.styleMask.rawValue == 32896 && $0.isVisible
        }) else {
            log("[B] menuBarWindow not found — fallback")
            return plainFallback(canChooseDirectories: canChooseDirectories)
        }
        log("[B] menuBarWindow=\(NSStringFromRect(menuBarWindow.frame)) children=\(menuBarWindow.childWindows?.count ?? 0)")

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.center()
        log("[B] panel centered to \(NSStringFromRect(panel.frame))")

        menuBarWindow.addChildWindow(panel, ordered: .above)
        log("[B] addChildWindow done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0) panel.parent=\(panel.parent == nil ? "nil" : "set")")

        // Activate so the non-activating-panel child can actually become key.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        log("[B] app activated, activationPolicy=regular")

        panel.makeKeyAndOrderFront(nil)
        log("[B] makeKeyAndOrderFront done — isKey=\(panel.isKeyWindow) isVisible=\(panel.isVisible)")

        dumpWindows(label: "B-before-runModal")
        log("[B] calling runModal")
        let result = panel.runModal()
        log("[B] runModal returned \(result == .OK ? "OK" : "Cancel") url=\(panel.url?.path ?? "nil")")

        menuBarWindow.removeChildWindow(panel)
        log("[B] removeChildWindow done")

        // Restore menubar-only appearance.
        NSApp.setActivationPolicy(.accessory)
        log("[B] activationPolicy restored to accessory")

        dumpWindows(label: "B-end")
        return result == .OK ? panel.url : nil
    }

    private static func plainFallback(canChooseDirectories: Bool) -> URL? {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        let result = panel.runModal()
        NSApp.setActivationPolicy(.accessory)
        return result == .OK ? panel.url : nil
    }
}
