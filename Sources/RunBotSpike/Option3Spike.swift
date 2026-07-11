// Option3Spike.swift
// RunBotSpike — spike/swiftui-lifecycle branch
//
// Minimal proof of concept for Option 3:
//   AppDelegate owns NSStatusItem + NSPopover.
//   NSHostingController wraps a pure SwiftUI view tree.
//   File picker via beginSheetModal(for: popoverWindow) — same pattern as main.
//   No MenuBarExtra. No .nonactivatingPanel. No outside-click fight.
//
// HOW TO RUN:
//   Swap @main from SheetSpikeApp to Option3App in this file,
//   or comment out @main on SheetSpikeApp in SheetPreservationSpike.swift.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import AppKit
import SwiftUI

// MARK: - Entry point
//
// NOTE: Only one @main is allowed per module.
// To run this spike, comment out @main on SheetSpikeApp
// in SheetPreservationSpike.swift and uncomment it here.

// @main  ← uncomment to run Option 3, comment out @main in SheetPreservationSpike.swift
struct Option3App: App {
    @NSApplicationDelegateAdaptor(Option3AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup, no MenuBarExtra.
        // All UI lives inside the NSPopover owned by Option3AppDelegate.
        // SwiftUI requires at least one Scene — Settings{} is the standard
        // empty placeholder for menu-bar-only apps.
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate
//
// Owns NSStatusItem and NSPopover — exactly the same shape as main's AppDelegate.
// SwiftUI views live inside NSHostingController, which is long-lived (owned by
// the popover). .task, @Observable, @Environment all behave correctly because
// the hosting controller is never recreated.

@MainActor
final class Option3AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: AppKit objects
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!

    // MARK: Outside-click monitor
    // Direct port of PopoverLifecycleCoordinator.outsideClickMonitor from main.
    // Guards against dismissal while NSOpenPanel is attached as a sheet.
    nonisolated(unsafe) private var outsideClickMonitor: Any?

    // MARK: App state
    // Owned here so it outlives the popover open/close cycle.
    private var appState = Option3AppState()

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
    }

    // MARK: - Status item

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

    // MARK: - Popover

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
        // .applicationDefined: we control dismiss via the outside-click monitor.
        // Same as main — popoverShouldClose always returns true; the monitor
        // guards against picker clicks via hasActiveSheet.
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

    // Convenience: the popover's backing NSWindow.
    // Non-nil only while the popover is shown.
    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    // MARK: - File picker
    //
    // Direct port of the working pattern from main:
    //   beginSheetModal(for: popoverWindow) attaches NSOpenPanel as a real sheet.
    //   popoverWindow.sheets is non-empty while the panel is open.
    //   The outside-click monitor checks hasActiveSheet before calling closePopover().

    func openFilePicker() {
        guard let window = popoverWindow else {
            print("[Option3] openFilePicker — popoverWindow nil")
            return
        }
        print("[Option3] openFilePicker — opening NSOpenPanel via beginSheetModal")

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder"
        panel.prompt = "Select"
        panel.beginSheetModal(for: window) { [weak self] response in
            print("[Option3] openFilePicker — response=\(response.rawValue) sheets=\(window.sheets.count)")
            guard response == .OK, let url = panel.url else { return }
            self?.appState.pickedFolderPath = url.path
            print("[Option3] openFilePicker — picked: \(url.path)")
        }
        // Log sheets count synchronously — should be 1 now.
        print("[Option3] openFilePicker — after beginSheetModal sheets=\(window.sheets.count)")
    }

    // MARK: - Outside-click monitor
    //
    // Port of PopoverLifecycleCoordinator.installMonitors from main.
    // Key guard: skip closePopover() when hasActiveSheet is true
    // (i.e. NSOpenPanel is attached via beginSheetModal).

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }

                // THE KEY GUARD — same as main's hasActiveSheet check.
                // While NSOpenPanel is attached as a sheet, sheets is non-empty
                // and every outside click is ignored.
                let hasActiveSheet = !(self.popoverWindow?.sheets.isEmpty ?? true)
                guard !hasActiveSheet else {
                    print("[Option3] outsideClickMonitor — sheet active, suppressing dismiss")
                    return
                }

                // Check the click landed outside the popover window.
                let screenLoc = event.window?.convertToScreen(
                    NSRect(origin: event.locationInWindow, size: .zero)
                ).origin ?? NSEvent.mouseLocation

                if let window = self.popoverWindow, window.frame.contains(screenLoc) {
                    return
                }

                print("[Option3] outsideClickMonitor — outside click, closing popover")
                self.closePopover()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    deinit {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - NSPopoverDelegate

extension Option3AppDelegate: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Always true — never block AppKit here.
        // The outside-click monitor is the sole gatekeeper.
        // Same rationale as main's AppDelegate+PanelSetup.swift.
        true
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
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

            GroupBox("@State counter (survives open/close)") {
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
