// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH A ONLY: .fileImporter + anchoredFileImporter
//
// The anchoredFileImporter modifier hooks .onChange(of: isPresented),
// waits one run-loop turn for SwiftUI to create the picker NSWindow,
// then calls menuBarWindow.addChildWindow(pickerWindow, ordered: .above).
// This puts the picker in the MenuBarExtra focus group so clicks inside
// it are NOT treated as outside-clicks that dismiss the panel.
//
// STATE FIX for outside-dismiss reopen:
//   When the user clicks outside the picker (not OK/Cancel), SwiftUI
//   sets isImporting = false but the NSOpenPanel is still alive/stale.
//   A subsequent tap sets isImporting = true but SwiftUI coalesces the
//   false→true on the same run-loop pass and skips re-presentation.
//   Fix: explicitly set false first, then async-dispatch true, forcing
//   a genuine two-step state transition SwiftUI must process.
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

            Button("Pick File") {
                log("A ► tapped isImporting=\(isImporting)")
                // Force a real false→true transition even if a previous
                // outside-dismiss already left isImporting = false.
                isImporting = false
                DispatchQueue.main.async {
                    log("A ► async: setting isImporting = true")
                    isImporting = true
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
                log("A ► success url=\(url.path)")
                pickedURL = url
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

// MARK: - anchoredFileImporter
//
// Drop-in replacement for .fileImporter. After SwiftUI creates the picker
// NSWindow (detected one run-loop turn after isPresented flips true), it
// calls menuBarWindow.addChildWindow(pickerWindow, ordered: .above) so
// the picker is in the MenuBarExtra focus group and clicks inside it are
// not treated as outside-clicks.

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
            ) { result in
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
    log("[anchorAndCenter] called")
    dumpWindows(label: "anchorAndCenter-start")

    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
    }) else {
        log("[anchorAndCenter] ERROR: MenuBarExtra window not found")
        return
    }
    log("[anchorAndCenter] menuBarWindow=\(NSStringFromRect(menuBarWindow.frame)) children=\(menuBarWindow.childWindows?.count ?? 0)")

    // One run-loop pass to let SwiftUI finish creating the picker window.
    DispatchQueue.main.async {
        log("[anchorAndCenter] async hop")
        dumpWindows(label: "anchorAndCenter-async")

        guard let pickerWindow = NSApp.windows.first(where: {
            $0 !== menuBarWindow
                && $0.isKeyWindow
                && $0.parent == nil
        }) else {
            log("[anchorAndCenter] ERROR: picker window not found after async hop")
            // Second hop in case SwiftUI needs another pass.
            DispatchQueue.main.async {
                log("[anchorAndCenter] second async hop")
                dumpWindows(label: "anchorAndCenter-second-hop")
                guard let pickerWindow = NSApp.windows.first(where: {
                    $0 !== menuBarWindow && $0.isKeyWindow && $0.parent == nil
                }) else {
                    log("[anchorAndCenter] ERROR: picker window STILL not found — giving up")
                    return
                }
                pickerWindow.center()
                menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
                log("[anchorAndCenter] second-hop anchor done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")
            }
            return
        }

        pickerWindow.center()
        menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
        log("[anchorAndCenter] anchor done — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")
    }
}
