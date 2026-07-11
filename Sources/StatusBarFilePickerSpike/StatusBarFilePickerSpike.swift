// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// DEBUG BUILD — heavy logging enabled throughout.
// Paste the full console output when reporting issues.
//
// TWO APPROACHES UNDER TEST:
// A) .fileImporter + anchoredFileImporter modifier
// B) NSOpenPanel anchored + centered manually
//
// HOW TO RUN:
//   swift run StatusBarFilePickerSpike 2>&1 | tee /tmp/filepicker-spike.log
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

            GroupBox("Approach A — .fileImporter (anchored)") {
                Button("Pick File (fileImporter)") {
                    log("A ► button tapped — isImporting before reset: \(isImporting)")
                    isImporting = false
                    log("A ► isImporting set false, scheduling async true")
                    DispatchQueue.main.async {
                        log("A ► async block fired — setting isImporting = true")
                        isImporting = true
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Watch console for anchor/window events.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Approach B — NSOpenPanel (anchored + centered)") {
                Button("Pick File (NSOpenPanel)") {
                    log("B ► button tapped")
                    pickedURL = FilePickerHelper.pickFile()
                    log("B ► pickFile returned: \(pickedURL?.path ?? "nil")")
                }
                .frame(maxWidth: .infinity)
                Text("Watch console for anchor/window events.")
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
        .anchoredFileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let url):
                log("A ► fileImporter onCompletion SUCCESS url=\(url.path)")
                pickedURL = url
            case .failure(let error):
                log("A ► fileImporter onCompletion FAILURE error=\(error)")
            }
        }
        .onChange(of: isImporting) { old, new in
            log("A ► isImporting changed \(old) → \(new) — windows:")
            dumpWindows()
        }
    }
}

// MARK: - Window dump helper

@MainActor
private func dumpWindows() {
    let wins = NSApp.windows
    log("  total windows: \(wins.count)")
    for (i, w) in wins.enumerated() {
        log("  [\(i)] \(type(of: w)) isKey=\(w.isKeyWindow) isMain=\(w.isMainWindow) isVisible=\(w.isVisible) styleMask=\(w.styleMask.rawValue) frame=\(NSStringFromRect(w.frame)) parent=\(w.parent == nil ? "nil" : String(describing: type(of: w.parent!))) children=\(w.childWindows?.count ?? 0)")
    }
}

// MARK: - anchoredFileImporter modifier
//
// Approach A: drop-in .fileImporter that anchors the picker NSWindow
// as a child of the MenuBarExtra window after SwiftUI creates it.

extension View {
    func anchoredFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
        self
            .fileImporter(
                isPresented: isPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection
            ) { (result: Result<[URL], Error>) in
                switch result {
                case .success(let urls):
                    if let url = urls.first { onCompletion(.success(url)) }
                case .failure(let err):
                    onCompletion(.failure(err))
                }
            }
            .onChange(of: isPresented.wrappedValue) { _, newValue in
                log("[anchoredFileImporter] onChange isPresented=\(newValue)")
                guard newValue else {
                    log("[anchoredFileImporter] isPresented false — skipping")
                    return
                }
                log("[anchoredFileImporter] scheduling anchorAndCenterPickerWindow")
                Task { @MainActor in anchorAndCenterPickerWindow() }
            }
    }
}

@MainActor
private func anchorAndCenterPickerWindow() {
    log("[anchorAndCenter] called — windows now:")
    dumpWindows()

    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    }) else {
        log("[anchorAndCenter] ERROR: MenuBarExtra window not found")
        return
    }
    log("[anchorAndCenter] menuBarWindow frame=\(NSStringFromRect(menuBarWindow.frame)) styleMask=\(menuBarWindow.styleMask.rawValue) children=\(menuBarWindow.childWindows?.count ?? 0)")

    DispatchQueue.main.async {
        log("[anchorAndCenter] async hop — windows now:")
        dumpWindows()

        guard let pickerWindow = NSApp.windows.first(where: {
            $0 !== menuBarWindow && $0.isKeyWindow && $0.parent == nil
        }) else {
            log("[anchorAndCenter] ERROR: picker window not found after async hop")
            // Second hop in case SwiftUI needs more time
            DispatchQueue.main.async {
                log("[anchorAndCenter] second async hop — windows now:")
                dumpWindows()
                guard let pickerWindow2 = NSApp.windows.first(where: {
                    $0 !== menuBarWindow && $0.isKeyWindow && $0.parent == nil
                }) else {
                    log("[anchorAndCenter] ERROR: picker window STILL not found after second hop — giving up")
                    return
                }
                log("[anchorAndCenter] found picker on second hop: \(type(of: pickerWindow2)) frame=\(NSStringFromRect(pickerWindow2.frame))")
                pickerWindow2.center()
                menuBarWindow.addChildWindow(pickerWindow2, ordered: .above)
                log("[anchorAndCenter] second-hop anchor done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")
            }
            return
        }
        log("[anchorAndCenter] found picker: \(type(of: pickerWindow)) frame=\(NSStringFromRect(pickerWindow.frame)) styleMask=\(pickerWindow.styleMask.rawValue)")
        pickerWindow.center()
        log("[anchorAndCenter] picker centered to frame=\(NSStringFromRect(pickerWindow.frame))")
        menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
        log("[anchorAndCenter] addChildWindow done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")
    }
}

// MARK: - NSOpenPanel helper (Approach B)
//
// @MainActor is required: all AppKit window/panel APIs are main-actor-isolated.

@MainActor
enum FilePickerHelper {

    static func pickFile(canChooseDirectories: Bool = false) -> URL? {
        log("[B] pickFile start — windows:")
        dumpWindows()

        guard let menuBarWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            log("[B] ERROR: MenuBarExtra window not found — falling back")
            return plainPickFile(canChooseDirectories: canChooseDirectories)
        }
        log("[B] menuBarWindow frame=\(NSStringFromRect(menuBarWindow.frame)) styleMask=\(menuBarWindow.styleMask.rawValue) children=\(menuBarWindow.childWindows?.count ?? 0)")

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        log("[B] panel frame before center: \(NSStringFromRect(panel.frame))")
        panel.center()
        log("[B] panel frame after center: \(NSStringFromRect(panel.frame))")

        let delegate = PanelDelegate()
        panel.delegate = delegate
        log("[B] delegate installed")

        log("[B] calling addChildWindow")
        menuBarWindow.addChildWindow(panel, ordered: .above)
        log("[B] addChildWindow done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0) panel.parent=\(panel.parent == nil ? "nil" : "set")")

        log("[B] calling makeKeyAndOrderFront")
        panel.makeKeyAndOrderFront(nil)
        log("[B] panel isKeyWindow=\(panel.isKeyWindow) isVisible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame))")

        log("[B] windows before runModal:")
        dumpWindows()

        log("[B] calling runModal — blocking")
        let result = panel.runModal()
        log("[B] runModal returned: \(result == .OK ? "OK" : "Cancel") url=\(panel.url?.path ?? "nil")")

        log("[B] windows after runModal:")
        dumpWindows()

        log("[B] calling removeChildWindow")
        menuBarWindow.removeChildWindow(panel)
        log("[B] removeChildWindow done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")

        return result == .OK ? panel.url : nil
    }

    private static func plainPickFile(canChooseDirectories: Bool) -> URL? {
        log("[B-fallback] activation-dance start")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        let result = panel.runModal()
        log("[B-fallback] runModal returned: \(result == .OK ? "OK" : "Cancel")")
        NSApp.setActivationPolicy(.accessory)
        return result == .OK ? panel.url : nil
    }
}

// MARK: - Panel delegate (Approach B logging)

private final class PanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panelSelectionDidChange(_ sender: Any?) {
        log("[B-delegate] panelSelectionDidChange")
    }
    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        log("[B-delegate] didChangeToDirectoryURL: \(url?.path ?? "nil")")
    }
    func panel(_ sender: Any, validate url: URL) throws {
        log("[B-delegate] validate url=\(url.path)")
    }
    func panel(_ sender: Any, willExpand expanding: Bool) {
        log("[B-delegate] willExpand expanding=\(expanding)")
    }
}
