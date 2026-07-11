// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// PURPOSE:
// Verifies that a file picker works inside a .window-style MenuBarExtra
// without the panel closing when the user clicks inside the picker.
//
// ROOT CAUSE (same as .sheet in PR #2033):
// NSOpenPanel / .fileImporter both create a new NSWindow that becomes key.
// MenuBarExtra treats any key-window change to a non-child window as an
// "outside click" and closes its panel. Fix: call addChildWindow on the
// picker window so it shares the MenuBarExtra's focus group.
//
// TWO APPROACHES UNDER TEST:
//
// A) .fileImporter + AnchoredOpenPanelModifier
//    .onChange(of: isImporting) detects the flip to true, waits one
//    run-loop turn for SwiftUI to create the picker NSWindow, then calls
//    menuBarWindow.addChildWindow(pickerWindow, ordered: .above).
//
// B) NSOpenPanel anchored manually
//    Same addChildWindow trick but applied directly before runModal().
//    The MenuBarExtra window is found, the panel is added as a child,
//    runModal() blocks, then the child relationship is removed on close.
//
// HOW TO RUN:
//   swift run StatusBarFilePickerSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears.
//   2. Click icon → window-style panel shows (NOT a plain menu list).
//   3. Click "Pick File (fileImporter)" → file picker appears.
//      Clicking anywhere inside picker must NOT close the panel.
//   4. Cancel → panel still open, label shows "(none)".
//   5. Pick a file → panel still open, label shows file name.
//   6. Click "Pick File (NSOpenPanel)" → same behaviour as A.
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

            // Approach A: .fileImporter anchored via AnchoredOpenPanelModifier
            GroupBox("Approach A — .fileImporter (anchored)") {
                Button("Pick File (fileImporter)") { isImporting = true }
                    .frame(maxWidth: .infinity)
                Text("Picker window is added as a child of the MenuBarExtra window.\nPanel must stay open while picker is shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Approach B: NSOpenPanel anchored manually
            GroupBox("Approach B — NSOpenPanel (anchored)") {
                Button("Pick File (NSOpenPanel)") {
                    pickedURL = FilePickerHelper.pickFile()
                }
                .frame(maxWidth: .infinity)
                Text("addChildWindow before runModal() keeps panel alive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            GroupBox("Last picked") {
                Text(pickedURL?.lastPathComponent ?? "(none)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(pickedURL == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if pickedURL != nil {
                    Button("Clear") { pickedURL = nil }.font(.caption)
                }
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 280)
        .anchoredFileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            pickedURL = try? result.get()
        }
        .task(id: isImporting) {
            print("[FilePickerSpike] isImporting: \(isImporting)")
        }
    }
}

// MARK: - AnchoredFileImporter
//
// Drop-in replacement for .fileImporter that parents the picker NSWindow
// to the MenuBarExtra window via addChildWindow(_:ordered:).
//
// Same technique as AnchoredSheetModifier in PR #2033, adapted for the
// open-panel window that .fileImporter creates.
//
// Detection heuristic for the picker window (one run-loop turn after isPresented flips):
//   - NOT the MenuBarExtra window (styleMask contains .nonactivatingPanel)
//   - Currently key window
//   - Not already a child of another window

extension View {
    func anchoredFileImporter<T: Transferable>(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
        self
            .fileImporter(
                isPresented: isPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection
            ) { result in
                onCompletion(result.map { $0 })
            }
            .onChange(of: isPresented.wrappedValue) { _, newValue in
                guard newValue else { return }
                Task { @MainActor in anchorPickerWindow() }
            }
    }

    // Non-generic overload for single-URL result used by ContentView
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
            ) { (result: Result<[URL], Error>) in
                switch result {
                case .success(let urls):
                    if let url = urls.first { onCompletion(.success(url)) }
                case .failure(let error):
                    onCompletion(.failure(error))
                }
            }
            .onChange(of: isPresented.wrappedValue) { _, newValue in
                guard newValue else { return }
                Task { @MainActor in anchorPickerWindow() }
            }
    }
}

@MainActor
private func anchorPickerWindow() {
    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    }) else {
        print("[AnchoredFilePicker] MenuBarExtra window not found")
        return
    }

    // One run-loop pass to let SwiftUI/AppKit finish creating the picker window.
    DispatchQueue.main.async {
        if let pickerWindow = NSApp.windows.first(where: {
            $0 !== menuBarWindow
                && $0.isKeyWindow
                && $0.parent == nil
        }) {
            print("[AnchoredFilePicker] anchoring picker window: \(pickerWindow)")
            menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
        } else {
            print("[AnchoredFilePicker] picker window not found — anchor skipped")
            NSApp.windows.forEach {
                print("  window: \($0) styleMask: \($0.styleMask) isKey: \($0.isKeyWindow) parent: \(String(describing: $0.parent))")
            }
        }
    }
}

// MARK: - NSOpenPanel helper (Approach B)
//
// Finds the MenuBarExtra window and adds the NSOpenPanel as a child before
// calling runModal(). Removes the child relationship after the panel closes.
// This prevents the outside-click monitor from treating picker focus as a
// dismissal event.

enum FilePickerHelper {

    static func pickFile(canChooseDirectories: Bool = false) -> URL? {
        guard let menuBarWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            print("[FilePickerHelper] MenuBarExtra window not found — falling back to plain runModal")
            return plainPickFile(canChooseDirectories: canChooseDirectories)
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        // Anchor the open panel as a child so focus transfer is not an outside-click.
        menuBarWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)

        let result = panel.runModal()

        // Remove child relationship after close.
        menuBarWindow.removeChildWindow(panel)

        return result == .OK ? panel.url : nil
    }

    // Fallback: plain activation-policy dance when no MenuBarExtra window is found.
    private static func plainPickFile(canChooseDirectories: Bool) -> URL? {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false

        let result = panel.runModal()
        NSApp.setActivationPolicy(.accessory)
        return result == .OK ? panel.url : nil
    }
}
