// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// PURPOSE:
// Verifies that a file picker (.fileImporter / NSOpenPanel) works reliably
// inside a .window-style MenuBarExtra without closing the panel.
//
// TWO APPROACHES UNDER TEST:
//
// A) SwiftUI .fileImporter modifier (preferred)
//    Wired directly to a Button inside the window-style panel.
//    The panel must stay visible while the file picker sheet is open.
//
// B) NSOpenPanel + activation-policy dance (fallback)
//    Used when .fileImporter is unavailable or closes the panel.
//    Temporarily promotes the app to .regular activation policy so the
//    open panel comes to front, then restores .accessory afterward.
//
// HOW TO RUN:
//   swift run StatusBarFilePickerSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears.
//   2. Click icon -> panel shows (window-style popover, NOT a plain menu).
//   3. Click "Pick File (fileImporter)" -> file picker appears over/beside the panel.
//      Panel must remain visible / not close.
//   4. Cancel -> picked URL stays nil. Label shows "(none)".
//   5. Pick a file -> label updates to the file path.
//   6. Click "Pick File (NSOpenPanel)" -> NSOpenPanel appears IN FRONT of all windows.
//   7. Repeat both paths 5x — no crashes, no stuck state.
//
// REQUIREMENTS: macOS 26, Swift 6
// DEPENDENCIES: none (zero RunBot deps)

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

            // Approach A: SwiftUI .fileImporter
            GroupBox("Approach A — .fileImporter") {
                Button("Pick File (fileImporter)") {
                    isImporting = true
                }
                .frame(maxWidth: .infinity)
                Text("Panel must stay open while picker is shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Approach B: NSOpenPanel via activation-policy dance
            GroupBox("Approach B — NSOpenPanel") {
                Button("Pick File (NSOpenPanel)") {
                    if let url = FilePickerHelper.pickFile() {
                        pickedURL = url
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Uses activation-policy dance to bring panel to front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Result readout
            GroupBox("Last picked") {
                Text(pickedURL?.lastPathComponent ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(pickedURL == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if pickedURL != nil {
                    Button("Clear") { pickedURL = nil }
                        .font(.caption)
                }
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 280)
        // Approach A wiring
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                pickedURL = urls.first
            }
        }
    }
}

// MARK: - NSOpenPanel helper (Approach B)
//
// .window-style MenuBarExtra runs with .accessory activation policy.
// Without the dance below, NSOpenPanel can appear behind other windows.

enum FilePickerHelper {

    /// Presents an `NSOpenPanel` and returns the selected URL, or `nil` if cancelled.
    ///
    /// Temporarily promotes the app to `.regular` activation policy so the panel
    /// becomes key and appears in front, then restores `.accessory` afterward.
    static func pickFile(canChooseDirectories: Bool = false) -> URL? {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let result = panel.runModal()

        NSApp.setActivationPolicy(.accessory)

        return result == .OK ? panel.url : nil
    }
}
