// StatusBarFilePickerSpike.swift
// StatusBarFilePickerSpike — spike/statusbar-filepicker branch
//
// APPROACH: MenuBarExtra(.window) + .fileImporter + anchoredFileImporter
//
// REQUIREMENTS: macOS 14+, Swift 6
// DEPENDENCIES: none

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Logging
// GUI apps don’t have stdout connected to the terminal.
// Write directly to a file so `tail -f` works in a single terminal session.

private let logFile: FileHandle? = {
    let path = "/tmp/filepicker-spike.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

private func log(_ msg: String, function: String = #function, line: Int = #line) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(function):\(line) \(msg)\n"
    logFile?.write(line.data(using: .utf8)!)
}

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
                log("► tapped isImporting=\(isImporting) id=\(fileImporterID)")
                isImporting = false
                DispatchQueue.main.async {
                    log("► async: setting isImporting=true")
                    isImporting = true
                }
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
            log("► picked \(pickedURL?.lastPathComponent ?? "nil")")
        }
        .id(fileImporterID)
        .onChange(of: isImporting) { _, v in log("isImporting → \(v) id=\(fileImporterID)") }
        .onChange(of: fileImporterID) { _, v in log("fileImporterID → \(v)") }
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
                log("[fileImporter] completion")
                removeObserver()
                switch result {
                case .success(let urls):
                    if let url = urls.first { onCompletion(.success(url)) }
                case .failure(let err):
                    onCompletion(.failure(err))
                }
            }
            .onChange(of: isPresented) { _, newValue in
                log("[modifier] onChange isPresented=\(newValue)")
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
            log("[modifier] observer removed")
        }
    }
}

@MainActor
private func anchorAndObserve(
    isPresented: Binding<Bool>,
    fileImporterID: Binding<Int>,
    closeObserver: Binding<(any NSObjectProtocol)?>
) {
    log("[anchor] called")
    dumpWindows(label: "anchor-start")

    guard let menuBarWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
    }) else { log("[anchor] ERROR: no menuBarWindow"); return }

    DispatchQueue.main.async {
        log("[anchor] async hop")
        dumpWindows(label: "anchor-async")

        guard let panel = NSApp.windows.first(where: {
            $0 is NSOpenPanel && $0.isKeyWindow && $0.parent == nil
        }) else { log("[anchor] ERROR: no NSOpenPanel found"); return }

        log("[anchor] found panel, anchoring")
        panel.center()
        menuBarWindow.addChildWindow(panel, ordered: .above)

        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            log("[anchor] willClose isPresented=\(isPresented.wrappedValue)")
            if let parent = panel.parent { parent.removeChildWindow(panel) }
            NotificationCenter.default.removeObserver(closeObserver.wrappedValue as Any)
            closeObserver.wrappedValue = nil
            guard isPresented.wrappedValue else {
                log("[anchor] willClose: OK/Cancel path, nothing to do")
                return
            }
            log("[anchor] willClose: outside-dismiss detected, bumping id")
            fileImporterID.wrappedValue += 1
            isPresented.wrappedValue = false
        }
        closeObserver.wrappedValue = obs
        log("[anchor] observer registered")
    }
}

@MainActor
private func dumpWindows(label: String) {
    let wins = NSApp.windows
    log("[windows:\(label)] total=\(wins.count)")
    for (i, w) in wins.enumerated() {
        log("  [\(i)] \(type(of: w)) isKey=\(w.isKeyWindow) isVisible=\(w.isVisible) parent=\(w.parent == nil ? "nil" : "set")")
    }
}
