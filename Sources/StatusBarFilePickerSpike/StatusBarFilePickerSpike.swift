// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH: MenuBarExtra(.window) + .fileImporter + anchoredFileImporter
//
// ANCHOR: onChange(of: isPresented) → wait one run-loop → find NSOpenPanel
// → addChildWindow so clicks inside don’t dismiss the MenuBarExtra.
//
// OUTSIDE-DISMISS REOPEN FIX:
// Child windows never resign key, so didResignKeyNotification doesn’t fire.
// Instead observe NSWindow.willCloseNotification on the panel.
// willClose fires for ALL dismissals (OK, Cancel, outside-click).
// OK/Cancel also call the .fileImporter completion handler which sets
// isPresented = false. Outside-click does NOT — so we detect it by
// checking isPresented.wrappedValue == true inside willClose.
// On outside-dismiss: increment fileImporterID to force SwiftUI to
// tear down and recreate .fileImporter (discarding the zombie panel),
// then set isPresented = false.
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
    @State private var fileImporterID = 0
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
        .anchoredFileImporter(
            isPresented: $isImporting,
            fileImporterID: $fileImporterID,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
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
        fileImporterID: Binding<Int>,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
        modifier(AnchoredFileImporterModifier(
            isPresented: isPresented,
            fileImporterID: fileImporterID,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            onCompletion: onCompletion
        ))
    }
}

private struct AnchoredFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var fileImporterID: Int
    let allowedContentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onCompletion: (Result<URL, Error>) -> Void
    @State private var closeObserver: (any NSObjectProtocol)?

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
                        fileImporterID: $fileImporterID,
                        closeObserver: $closeObserver
                    )
                }
            }
    }

    private func removeObserver() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
    }
}

@MainActor
private func anchorAndObserve(
    isPresented: Binding<Bool>,
    fileImporterID: Binding<Int>,
    closeObserver: Binding<(any NSObjectProtocol)?>
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

        // willClose fires for every dismissal path.
        // If isPresented is still true when it fires, SwiftUI didn’t handle
        // it (outside-click). Force a teardown so next tap gets a fresh panel.
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            if let parent = panel.parent { parent.removeChildWindow(panel) }
            NotificationCenter.default.removeObserver(closeObserver.wrappedValue as Any)
            closeObserver.wrappedValue = nil
            guard isPresented.wrappedValue else { return }
            // Outside-dismiss: SwiftUI still thinks panel is open.
            // Bump ID to force modifier teardown, then clear state.
            fileImporterID.wrappedValue += 1
            isPresented.wrappedValue = false
        }
        closeObserver.wrappedValue = obs
    }
}
