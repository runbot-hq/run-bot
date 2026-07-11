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
// STATE / ZOMBIE FIX:
//   After an outside-dismiss, SwiftUI leaves the NSOpenPanel alive but
//   invisible (isVisible=false, isKey=false, parent=nil). On the next
//   tap SwiftUI reuses that same instance — it never becomes key, so the
//   old anchor search (isKeyWindow==true) always fails.
//
//   Fix: in anchorAndCenterPickerWindow, before hunting for a key window,
//   close and remove ALL stale invisible NSOpenPanel instances from
//   NSApp.windows. This forces SwiftUI to create a fresh one, which will
//   become key as normal.
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
                guard newValue else { return }
                Task { @MainActor in anchorAndCenterPickerWindow() }
            }
    }
}

// MARK: - Anchor helper
//
// Strategy:
//   1. Kill all stale invisible NSOpenPanel zombies FIRST. These are panels
//      from prior outside-dismissals that SwiftUI left alive. SwiftUI will
//      reuse them and they never become key, breaking the anchor search.
//      Closing them forces SwiftUI to allocate a fresh panel that will
//      become key as expected.
//   2. Wait one run-loop turn for SwiftUI to create (or show) the new panel.
//   3. Find it by isKeyWindow == true, center it, addChildWindow.

@MainActor
private func anchorAndCenterPickerWindow() {
    log("[anchorAndCenter] called")

    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
    }) else {
        log("[anchorAndCenter] ERROR: MenuBarExtra window not found")
        return
    }

    // Step 1: close stale invisible NSOpenPanel zombies.
    let zombies = NSApp.windows.filter { $0 is NSOpenPanel && !$0.isVisible }
    if !zombies.isEmpty {
        log("[anchorAndCenter] closing \(zombies.count) zombie NSOpenPanel(s)")
        zombies.forEach {
            if let parent = $0.parent { parent.removeChildWindow($0) }
            $0.close()
        }
        dumpWindows(label: "after-zombie-close")
    }

    // Step 2: one run-loop pass for SwiftUI to create/show the fresh panel.
    DispatchQueue.main.async {
        log("[anchorAndCenter] async hop")
        dumpWindows(label: "anchorAndCenter-async")

        func anchor(in windows: [NSWindow]) -> Bool {
            guard let pickerWindow = windows.first(where: {
                $0 is NSOpenPanel && $0.isKeyWindow && $0.parent == nil
            }) else { return false }
            pickerWindow.center()
            menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
            log("[anchorAndCenter] anchored \(type(of: pickerWindow)) — menuBar.children=\(menuBarWindow.childWindows?.count ?? 0)")
            return true
        }

        if anchor(in: NSApp.windows) { return }

        // One more hop in case SwiftUI needs an extra pass.
        log("[anchorAndCenter] picker not key yet — second hop")
        DispatchQueue.main.async {
            dumpWindows(label: "anchorAndCenter-second-hop")
            if !anchor(in: NSApp.windows) {
                log("[anchorAndCenter] ERROR: picker STILL not key — giving up")
            }
        }
    }
}
