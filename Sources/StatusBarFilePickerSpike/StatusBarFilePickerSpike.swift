// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH: NSOpenPanel.runModal() on a detached Thread.
//
// WHY NOT DispatchQueue.global:
//   runModal() spins its own NSRunLoop. GCD threads don’t have a run loop
//   by default and the call returns immediately. NSThread does.
//
// WHY THIS WORKS WITHOUT ACTIVATION:
//   runModal() calls orderFrontRegardless() internally, which bypasses the
//   normal activation requirement. The panel appears on screen and receives
//   events without the app needing to be active or have a Dock icon.
//
// WHY THE MENUBAR STAYS OPEN:
//   The main run loop keeps pumping normally — we’re not blocking it.
//   MenuBarExtra continues to handle events. The panel has its own modal
//   event loop on the secondary thread.
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
// Runs NSOpenPanel.runModal() on a detached NSThread so the main run loop
// is never blocked. Delivers the result back on the main actor.

func pickFile(completion: @escaping @MainActor (URL?) -> Void) {
    Thread.detachNewThread {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let response = panel.runModal()
        let url = response == .OK ? panel.url : nil
        DispatchQueue.main.async {
            Task { @MainActor in completion(url) }
        }
    }
}
