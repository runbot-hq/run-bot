// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// NSOpenPanel must be created and configured on the main thread.
// runModal() is then called on a detached NSThread so the main run loop
// is never blocked and the MenuBarExtra stays open.
// No activation policy change. No Dock bounce.
//
// REQUIREMENTS: macOS 26, Swift 6
// DEPENDENCIES: none

import AppKit
import SwiftUI

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
                pickFile { url in pickedURL = url }
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
                    Button("Clear") { pickedURL = nil }.font(.caption)
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

// MARK: - File picker
//
// 1. Create and configure NSOpenPanel on the main thread (AppKit requirement).
// 2. Hand the configured panel to a detached NSThread.
// 3. Call runModal() there — it blocks that thread, not the main run loop.
// 4. Deliver result back on the main actor.

@MainActor
func pickFile(completion: @escaping @MainActor (URL?) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    Thread.detachNewThread {
        let response = panel.runModal()
        let url = response == .OK ? panel.url : nil
        DispatchQueue.main.async {
            Task { @MainActor in completion(url) }
        }
    }
}
