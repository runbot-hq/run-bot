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
// "outside click" and closes its panel. Fix: addChildWindow so the picker
// shares the MenuBarExtra’s focus group.
//
// TWO APPROACHES UNDER TEST:
//
// A) .fileImporter + anchoredFileImporter modifier
//    .onChange(of: isImporting) detects the flip to true, waits one
//    run-loop turn for SwiftUI to create the picker NSWindow, then calls
//    menuBarWindow.addChildWindow(pickerWindow, ordered: .above).
//
//    KNOWN QUIRK: if the picker was previously dismissed by clicking outside
//    (not via Cancel/OK), isImporting may already be false so the binding
//    never re-fires. Fix: explicitly reset isImporting = false before setting
//    it true, forcing a real state change SwiftUI can observe.
//
// B) NSOpenPanel anchored + centered manually
//    addChildWindow before runModal() to keep the panel alive.
//    NSOpenPanel is explicitly centered on the main screen before showing
//    so it doesn’t anchor to the MenuBarExtra window’s top-left corner.
//
// HOW TO RUN:
//   swift run StatusBarFilePickerSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears.
//   2. Click icon → window-style panel shows (NOT a plain menu list).
//   3. Click "Pick File (fileImporter)" → file picker appears centered.
//      Clicking anywhere inside picker must NOT close the panel.
//      Re-trigger after outside-dismiss must work reliably.
//   4. Cancel → panel still open, label shows "(none)".
//   5. Pick a file → panel still open, label shows file name.
//   6. Click "Pick File (NSOpenPanel)" → same, centered on screen.
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

            // Approach A: .fileImporter anchored as child window
            GroupBox("Approach A — .fileImporter (anchored)") {
                Button("Pick File (fileImporter)") {
                    // Reset first to force a state change even if a previous
                    // outside-dismiss left isImporting = false without re-triggering.
                    isImporting = false
                    // Dispatch to next run-loop so the false → true transition
                    // is a genuine two-step flip SwiftUI observes.
                    DispatchQueue.main.async { isImporting = true }
                }
                .frame(maxWidth: .infinity)
                Text("Picker anchored as child window. Re-triggers reliably after outside-dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Approach B: NSOpenPanel anchored + centered
            GroupBox("Approach B — NSOpenPanel (anchored + centered)") {
                Button("Pick File (NSOpenPanel)") {
                    pickedURL = FilePickerHelper.pickFile()
                }
                .frame(maxWidth: .infinity)
                Text("addChildWindow keeps panel alive. Panel centered on screen.")
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

// MARK: - anchoredFileImporter modifier
//
// Drop-in replacement for .fileImporter that parents the picker NSWindow
// to the MenuBarExtra window via addChildWindow(_:ordered:).
//
// Same technique as AnchoredSheetModifier in PR #2033.
//
// Picker window detection (one run-loop turn after isPresented flips true):
//   - NOT the MenuBarExtra window (styleMask contains .nonactivatingPanel)
//   - Currently key window
//   - No existing parent (not already anchored)

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
                Task { @MainActor in anchorAndCenterPickerWindow() }
            }
    }
}

@MainActor
private func anchorAndCenterPickerWindow() {
    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    }) else {
        print("[AnchoredFilePicker] MenuBarExtra window not found")
        return
    }

    // One run-loop pass to let SwiftUI finish creating the picker window.
    DispatchQueue.main.async {
        guard let pickerWindow = NSApp.windows.first(where: {
            $0 !== menuBarWindow
                && $0.isKeyWindow
                && $0.parent == nil
        }) else {
            print("[AnchoredFilePicker] picker window not found — anchor skipped")
            NSApp.windows.forEach {
                print("  window: \($0) styleMask: \($0.styleMask) isKey: \($0.isKeyWindow) parent: \(String(describing: $0.parent))")
            }
            return
        }
        // Center on the main screen before anchoring so it doesn’t
        // inherit the MenuBarExtra window’s top-of-screen position.
        pickerWindow.center()
        menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
        print("[AnchoredFilePicker] anchored + centered picker window: \(pickerWindow)")
    }
}

// MARK: - NSOpenPanel helper (Approach B)
//
// Adds the NSOpenPanel as a child of the MenuBarExtra window before runModal()
// so focus transfer is not treated as an outside-click.
// Centers the panel on the main screen so it doesn’t inherit the
// MenuBarExtra window’s top-of-screen anchor position.

enum FilePickerHelper {

    static func pickFile(canChooseDirectories: Bool = false) -> URL? {
        guard let menuBarWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            print("[FilePickerHelper] MenuBarExtra window not found — falling back to activation-dance")
            return plainPickFile(canChooseDirectories: canChooseDirectories)
        }

        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        // Center on screen BEFORE anchoring so the child doesn’t inherit
        // the parent’s top-left screen origin.
        panel.center()

        menuBarWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)

        let result = panel.runModal()

        menuBarWindow.removeChildWindow(panel)

        return result == .OK ? panel.url : nil
    }

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
