// StatusBarFilePickerSpike.swift
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
    private weak var parentWindow: NSWindow?

    func show(completion: @escaping @MainActor (URL?) -> Void) {
        // ── DIAGNOSTICS ──────────────────────────────────────────────────────
        let panelState: String
        if let p = panel {
            panelState = "panel=\(type(of: p)) isVisible=\(p.isVisible) sheetParent=\(p.sheetParent.map { String(describing: type(of: $0)) } ?? "nil")"
        } else {
            panelState = "panel=nil"
        }
        let winState: String
        if let w = parentWindow {
            winState = "parentWindow=\(type(of: w)) isVisible=\(w.isVisible)"
        } else {
            winState = "parentWindow=nil(weak)"
        }
        log("show() called — \(panelState) | \(winState)")
        log("all windows: \(NSApp.windows.map { "\(type(of: $0))(visible=\($0.isVisible))" }.joined(separator: ", "))")
        // ─────────────────────────────────────────────────────────────────────

        if panel != nil, parentWindow?.isVisible != true {
            log("stale panel — clearing directly")
            panel?.orderOut(nil)
            panel = nil
            parentWindow = nil
        }

        guard panel == nil else { log("already open"); return }

        guard let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
        }) else { log("ERROR: no MenuBarExtraWindow visible"); return }

        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        panel = p
        parentWindow = window
        log("opening sheet on \(type(of: window))")

        p.beginSheetModal(for: window) { [weak self] response in
            log("sheet done response=\(response == .OK ? "OK" : "Cancel")")
            self?.panel = nil
            self?.parentWindow = nil
            completion(response == .OK ? p.url : nil)
        }
    }
}
