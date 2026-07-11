// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// PURPOSE:
// Verifies that a file picker works reliably inside a .window-style
// MenuBarExtra without closing the panel.
//
// TWO APPROACHES UNDER TEST:
//
// A) SwiftUI .fileImporter (preferred)
//    Native modifier wired to a Button inside the window-style panel.
//    KNOWN RISK: .fileImporter may close the MenuBarExtra panel because the
//    open sheet steals key-window status (same root cause as .sheet — see PR #2033).
//    The .task(id: isImporting) log will reveal if the panel reopens mid-session.
//
// B) NSOpenPanel + activation-policy dance (fallback)
//    Temporarily promotes the app to .regular so the panel comes to front,
//    then restores .accessory afterward.
//    Bypasses SwiftUI entirely — panel close is not a risk.
//
// HOW TO RUN:
//   swift run StatusBarFilePickerSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears.
//   2. Click icon → window-style panel shows (NOT a plain menu list).
//   3. Click "Pick File (fileImporter)" → file picker appears.
//      ✔ Panel stays open behind the picker (check console — no "isImporting: false" mid-session).
//   4. Cancel → label stays "(none)".
//   5. Pick a file → label updates to the file name.
//   6. Click "Pick File (NSOpenPanel)" → NSOpenPanel appears IN FRONT of all windows.
//   7. Cancel → label unchanged. Pick → label updates.
//   8. Repeat both paths 5x — no crashes, no stuck state.
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
                Text("Panel must stay open while picker is shown.\nWatch console for spurious isImporting=false.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Approach B: NSOpenPanel + activation-policy dance
            GroupBox("Approach B — NSOpenPanel") {
                Button("Pick File (NSOpenPanel)") {
                    pickedURL = FilePickerHelper.pickFile()
                }
                .frame(maxWidth: .infinity)
                Text("Activation-policy dance: .regular → runModal() → .accessory.")
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
            pickedURL = try? result.get()
        }
        // Diagnostic: logs every time isImporting flips.
        // Spurious false during an open session = panel closed and reopened.
        .task(id: isImporting) {
            print("[FilePickerSpike] isImporting: \(isImporting)")
        }
    }
}

// MARK: - NSOpenPanel helper (Approach B)
//
// .window-style MenuBarExtra runs with .accessory activation policy.
// Without the dance below, NSOpenPanel appears behind other windows.

enum FilePickerHelper {

    /// Presents an `NSOpenPanel` and returns the selected `URL`, or `nil` if cancelled.
    ///
    /// Temporarily promotes the app to `.regular` activation policy so the panel
    /// becomes key and appears in front, then restores `.accessory` afterward.
    ///
    /// - Parameter canChooseDirectories: Also allow picking directories. Default `false`.
    static func pickFile(canChooseDirectories: Bool = false) -> URL? {
        // 1. Promote so the open panel can become key.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let result = panel.runModal()

        // 2. Restore .accessory so the Dock icon disappears again.
        NSApp.setActivationPolicy(.accessory)

        return result == .OK ? panel.url : nil
    }
}
