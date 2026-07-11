// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH: MenuBarExtra(.window) + SwiftUI .fileImporter
//
// anchoredFileImporter wraps .fileImporter and hooks onChange(of: isPresented).
// When isPresented flips true, it waits one run-loop turn for SwiftUI to
// create the NSOpenPanel window, then calls
// menuBarWindow.addChildWindow(panel, ordered: .above) to put the panel
// in the MenuBarExtra focus group. Clicks inside the panel are then NOT
// treated as outside-clicks.
//
// OUTSIDE-DISMISS REOPEN FIX:
// When the user clicks outside the panel (not OK/Cancel), the NSOpenPanel
// resigns key. We observe NSWindow.didResignKeyNotification on the panel
// and force-reset isPresented = false on the next run-loop so SwiftUI
// sees a clean false state. The button tap then does the normal
// false → async-true two-step which reliably re-triggers .fileImporter.
//
// REQUIREMENTS: macOS 14+, Swift 6
// DEPENDENCIES: none

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

            Button("Pick File") {
                // Force a genuine false→true transition every tap.
                isImporting = false
                DispatchQueue.main.async { isImporting = true }
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
        .anchoredFileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            pickedURL = try? result.get()
        }
    }
}

// MARK: - anchoredFileImporter
//
// Drop-in .fileImporter replacement that:
//   1. Anchors the NSOpenPanel as a child of the MenuBarExtra window so
//      clicks inside it don’t count as outside-clicks.
//   2. Observes NSWindow.didResignKeyNotification on the panel to detect
//      outside-dismiss and reset isPresented cleanly.

extension View {
    func anchoredFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
        self.modifier(
            AnchoredFileImporterModifier(
                isPresented: isPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection,
                onCompletion: onCompletion
            )
        )
    }
}

private struct AnchoredFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onCompletion: (Result<URL, Error>) -> Void

    // Holds the resign-key observer so we can remove it when done.
    @State private var resignObserver: (any NSObjectProtocol)?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
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
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    // Panel just appeared — anchor it on next run-loop.
                    Task { @MainActor in anchorPickerWindow(isPresented: $isPresented, resignObserver: $resignObserver) }
                } else {
                    // Dismissed via OK/Cancel — remove observer.
                    removeResignObserver()
                }
            }
    }

    private func removeResignObserver() {
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
    }
}

@MainActor
private func anchorPickerWindow(
    isPresented: Binding<Bool>,
    resignObserver: Binding<(any NSObjectProtocol)?>
) {
    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
    }) else { return }

    DispatchQueue.main.async {
        guard let panel = NSApp.windows.first(where: {
            $0 is NSOpenPanel && $0.isKeyWindow && $0.parent == nil
        }) else { return }

        panel.center()
        menuBarWindow.addChildWindow(panel, ordered: .above)

        // Observe outside-dismiss: panel resigns key without OK/Cancel.
        // Reset isPresented so the next tap gets a clean false state.
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            // Only act if SwiftUI hasn’t already cleared isPresented
            // (OK/Cancel clears it first; outside-dismiss doesn’t).
            guard isPresented.wrappedValue else { return }
            DispatchQueue.main.async {
                isPresented.wrappedValue = false
            }
        }
        resignObserver.wrappedValue = obs
    }
}
