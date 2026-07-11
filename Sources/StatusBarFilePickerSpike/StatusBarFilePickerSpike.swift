// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH: MenuBarExtra(.window) + SwiftUI .fileImporter
//
// OUTSIDE-DISMISS FIX:
// SwiftUI’s .fileImporter retains a stale NSOpenPanel after outside-dismiss.
// Setting isPresented = false is a no-op (it’s already false internally).
// The next tap’s false→true transition is coalesced and the panel never shows.
//
// Fix: track a `fileImporterID` integer. On outside-dismiss (detected via
// NSWindow.didResignKeyNotification while isPresented is still true),
// increment fileImporterID. The .id(fileImporterID) on the fileImporter
// target view forces SwiftUI to tear down and recreate the modifier entirely,
// discarding the zombie NSOpenPanel. The next tap then gets a fresh panel.
//
// ANCHOR:
// anchoredFileImporter wraps .fileImporter and calls addChildWindow after
// one run-loop hop so the panel is in the MenuBarExtra focus group and
// clicks inside it are not treated as outside-clicks.
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
    @State private var fileImporterID = 0   // increment to force .fileImporter teardown
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File Picker Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            Button("Pick File") {
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
        // .id forces SwiftUI to tear down and rebuild this modifier when
        // fileImporterID changes, discarding any stale NSOpenPanel.
        .anchoredFileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onOutsideDismiss: {
                // Increment ID — SwiftUI recreates .fileImporter from scratch.
                fileImporterID += 1
                isImporting = false
            }
        ) { result in
            pickedURL = try? result.get()
        }
        .id(fileImporterID)
    }
}

// MARK: - anchoredFileImporter

extension View {
    func anchoredFileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onOutsideDismiss: @escaping @MainActor () -> Void,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
        self.modifier(
            AnchoredFileImporterModifier(
                isPresented: isPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection,
                onOutsideDismiss: onOutsideDismiss,
                onCompletion: onCompletion
            )
        )
    }
}

private struct AnchoredFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onOutsideDismiss: @MainActor () -> Void
    let onCompletion: (Result<URL, Error>) -> Void
    @State private var resignObserver: (any NSObjectProtocol)?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: allowsMultipleSelection
            ) { result in
                removeObserver()
                switch result {
                case .success(let urls):
                    if let url = urls.first { onCompletion(.success(url)) }
                case .failure(let err):
                    onCompletion(.failure(err))
                }
            }
            .onChange(of: isPresented) { _, newValue in
                guard newValue else { removeObserver(); return }
                Task { @MainActor in
                    anchorAndObserve(
                        isPresented: $isPresented,
                        resignObserver: $resignObserver,
                        onOutsideDismiss: onOutsideDismiss
                    )
                }
            }
    }

    private func removeObserver() {
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
    }
}

@MainActor
private func anchorAndObserve(
    isPresented: Binding<Bool>,
    resignObserver: Binding<(any NSObjectProtocol)?>,
    onOutsideDismiss: @MainActor @escaping () -> Void
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

        // Detect outside-dismiss: panel loses key while isPresented is still true.
        // OK/Cancel completion clears isPresented first, so the guard filters those.
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            guard isPresented.wrappedValue else { return }
            NotificationCenter.default.removeObserver(resignObserver.wrappedValue as Any)
            resignObserver.wrappedValue = nil
            onOutsideDismiss()
        }
        resignObserver.wrappedValue = obs
    }
}
