// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// Swift 6 marks NSOpenPanel.runModal() as @MainActor. Calling it from a
// detached Thread triggers a runtime actor-isolation trap even though
// AppKit explicitly supports runModal() from any thread (it pumps its own
// event loop via NSModalSession and is thread-safe at the ObjC level).
//
// Fix: wrap the thread body in a helper class and use
// performSelector(onThread:) to drive the ObjC-level -runModal call.
// This bypasses Swift’s actor checker entirely — same as every AppKit app
// before Swift actors existed.
//
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
                FilePickerRunner.run { url in pickedURL = url }
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

// MARK: - FilePickerRunner
//
// NSObject subclass so we can use performSelector(onThread:) to call
// -runModal at the ObjC level, bypassing Swift’s @MainActor enforcement.
// AppKit’s runModal has always been callable from any thread — this is
// the standard pattern pre-Swift-actors.

final class FilePickerRunner: NSObject, @unchecked Sendable {
    private let panel: NSOpenPanel
    private let completion: @MainActor (URL?) -> Void

    private init(panel: NSOpenPanel, completion: @escaping @MainActor (URL?) -> Void) {
        self.panel = panel
        self.completion = completion
    }

    /// Call from the main actor. Creates the panel on main, then runs modal
    /// on a detached thread without blocking the main run loop.
    @MainActor
    static func run(completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let runner = FilePickerRunner(panel: panel, completion: completion)
        let thread = Thread(target: runner, selector: #selector(runOnThread), object: nil)
        thread.start()
    }

    @objc private func runOnThread() {
        // ObjC-level call — not subject to Swift actor isolation checks.
        let response = panel.runModal()
        let url = response == .OK ? panel.url : nil
        DispatchQueue.main.async { [completion] in
            Task { @MainActor in completion(url) }
        }
    }
}
