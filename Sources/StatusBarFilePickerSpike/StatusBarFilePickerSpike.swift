// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH: .fileImporter with Int counter state
//
// Problem with Bool binding:
//   SwiftUI coalesces false→true on the same run loop pass and skips
//   re-presentation if the underlying NSOpenPanel was dismissed externally
//   (outside-click). The panel stays invisible/stale but isPresented is
//   already false, so the next true is a no-op.
//
// Fix: drive .fileImporter with an Int (presentationID) instead of Bool.
//   SwiftUI treats any change in the bound value as a new event.
//   Incrementing on every tap always triggers a fresh presentation —
//   even if the previous one was dismissed externally.
//   The modifier maps Int != 0 as "presented".
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
    /// Incremented on every button tap. .fileImporter sees a new value
    /// each time, which forces SwiftUI to re-present the panel even if
    /// it was previously dismissed externally.
    @State private var presentationID = 0
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Picker Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Button("Pick File") {
                log("► tapped presentationID=\(presentationID)")
                presentationID += 1
                log("► presentationID now \(presentationID)")
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
        // fileImporter is driven by a Binding<Bool> derived from the counter.
        // We map presentationID != 0 as "presented" and reset to 0 on dismiss.
        .fileImporter(
            isPresented: Binding(
                get: { presentationID != 0 },
                set: { isPresented in
                    if !isPresented {
                        log("► fileImporter set false — resetting presentationID")
                        presentationID = 0
                    }
                }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                log("► success url=\(urls.first?.path ?? "nil")")
                pickedURL = urls.first
            case .failure(let err):
                log("► failure err=\(err)")
            }
        }
        .onChange(of: presentationID) { old, new in
            log("► presentationID \(old)→\(new)")
            dumpWindows(label: "presentationID-\(new)")
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
