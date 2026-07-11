// FileImporterSpike.swift
// RunBotFileImporterSpike — spike/fileimporter-menubarextra branch
//
// PURPOSE:
// Single focused question from issue #2028:
//
//   Does .fileImporter on macOS 26 keep the MenuBarExtra(.window)
//   window alive while the picker is open?
//
// If YES → the original plan in #2027/#2028 stands.
//          MenuBarExtra is the right path. Option 3 (NSPopover) is unnecessary.
// If NO  → Option 3 (NSPopover + beginSheetModal) is the correct architecture.
//
// HOW TO RUN:
//   swift run RunBotFileImporterSpike
//
// WHAT TO TEST:
//   1. Click “Pick folder…” — picker should appear
//   2. Click anywhere inside the picker (sidebar, files, buttons, edges)
//   3. PASS: MenuBarExtra window stays visible behind the picker
//   4. FAIL: MenuBarExtra window disappears on first click inside picker
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FileImporterSpikeApp: App {
    var body: some Scene {
        MenuBarExtra("\u{1F9EA}", systemImage: "flask.fill") {
            FileImporterSpikeView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct FileImporterSpikeView: View {
    @State private var showPicker = false
    @State private var pickedPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("fileImporter spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Button("Pick folder…") {
                showPicker = true
            }
            .frame(maxWidth: .infinity)

            if !pickedPath.isEmpty {
                Text(pickedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.primary)
            } else {
                Text("No folder picked yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Divider()

            Text("PASS: window stays open while picker is open")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("FAIL: window hides on first click inside picker")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                pickedPath = url.path
                print("[FileImporterSpike] picked: \(url.path)")
            case .failure(let error):
                print("[FileImporterSpike] error: \(error)")
            }
        }
    }
}
