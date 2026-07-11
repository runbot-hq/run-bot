// Option3Spike.swift
// RunBotSpike — spike/swiftui-lifecycle branch
//
// Minimal proof of concept for Option 3:
//   AppDelegate owns NSStatusItem + NSPopover.
//   NSHostingController wraps a pure SwiftUI view tree.
//   File picker via beginSheetModal(for: popoverWindow) — same pattern as main.
//   No MenuBarExtra. No .nonactivatingPanel. No outside-click fight.
//
// REQUIREMENTS: macOS 26+, Swift 6.2
//
// NOTE: @main lives in NavSheetSpike.swift on spike/swiftui-nav-sheet.

import AppKit
import SwiftUI

// @main ← moved to NavSheetSpike.swift
struct Option3App: App {
    @NSApplicationDelegateAdaptor(Option3AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

@MainActor
final class Option3AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    nonisolated(unsafe) private var outsideClickMonitor: Any?
    private var appState = Option3AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\u{1F9EA}"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func setupPopover() {
        let root = Option3RootView(onPickFolder: { [weak self] in
            self?.openFilePicker()
        })
        .environment(appState)

        hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 320, height: 200)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    func openFilePicker() {
        guard let window = popoverWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder"
        panel.prompt = "Select"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.appState.pickedFolderPath = url.path
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                let hasActiveSheet = !(self.popoverWindow?.sheets.isEmpty ?? true)
                guard !hasActiveSheet else { return }
                let loc = event.window?.convertToScreen(
                    NSRect(origin: event.locationInWindow, size: .zero)
                ).origin ?? NSEvent.mouseLocation
                if let w = self.popoverWindow, w.frame.contains(loc) { return }
                self.closePopover()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    deinit { if let m = outsideClickMonitor { NSEvent.removeMonitor(m) } }
}

extension Option3AppDelegate: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool { true }
    func popoverDidClose(_ notification: Notification) { removeOutsideClickMonitor() }
}

// MARK: - App state

@Observable
@MainActor
final class Option3AppState {
    var pickedFolderPath: String = ""
    var counter: Int = 0
    var text: String = ""
}

// MARK: - Root view

struct Option3RootView: View {
    @Environment(Option3AppState.self) private var appState
    let onPickFolder: () -> Void

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 14) {
            Text("Option 3 Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Counter (survives open/close)") {
                HStack {
                    Text("Counter: \(appState.counter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { appState.counter += 1 }
                }
            }

            GroupBox("TextField (survives open/close)") {
                TextField("Type here...", text: $appState.text)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox("File picker") {
                Button("Choose folder…") { onPickFolder() }
                if !appState.pickedFolderPath.isEmpty {
                    Text(appState.pickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text("Click anywhere in the picker. App should stay open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
