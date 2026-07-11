// NavSheetSpike.swift
// RunBotSpike - spike/swiftui-nav-sheet branch
//
// Builds on Option 3 (NSPopover + @NSApplicationDelegateAdaptor).
//
// DISMISS STRATEGY:
// NSPopover in a .accessory app uses a nonactivatingPanel window, so
// .transient never reliably fires. Instead:
//   - .behavior = .applicationDefined (AppKit never auto-closes)
//   - A global NSEvent monitor fires on every outside click and calls
//     popover.performClose(). No logic in the monitor — it just calls close.
//   - popoverShouldClose returns false when overlayCount > 0, blocking
//     dismissal while a sheet or file picker is open.
//   - overlayCount is managed explicitly (no childWindows inspection).
//
// STATUS BUTTON HIGHLIGHT:
// Pinned to popover.isShown via popoverWillShow / popoverDidClose.
//
// POPOVER ACTIVE APPEARANCE:
// The popover window is an NSPanel. When another window steals key focus
// the panel renders as "inactive" (dimmed border, washed-out controls).
// Fix: after the popover window exists, use object_setClass to replace its
// runtime class with AlwaysActivePopoverWindow, which overrides isKeyWindow
// to always return true. AppKit then always draws it as focused/active.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import AppKit
import ObjectiveC
import SwiftUI

// MARK: - AlwaysActivePopoverWindow
// Applied via object_setClass after the popover window is created.
// Overrides isKeyWindow so AppKit always renders with active appearance.
final class AlwaysActivePopoverWindow: NSPanel {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

// MARK: - Entry point

@main
struct NavSheetApp: App {
    @NSApplicationDelegateAdaptor(NavSheetAppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App state

enum NavSheetRoute: Equatable {
    case main
    case settings
}

@Observable
@MainActor
final class NavSheetAppState {
    var route: NavSheetRoute = .main
    var counter: Int = 0
    var text: String = ""
    var settingsCounter: Int = 0
    var settingsToggle: Bool = false
    var showSettingsSheet: Bool = false
    var sheetCounter: Int = 0
    var sheetText: String = ""
    var taskFireCount: Int = 0
    var pickedFolderPath: String = ""
    var sheetPickedFolderPath: String = ""
    var showSheetAlert: Bool = false
    var overlayCount: Int = 0
}

// MARK: - AppDelegate

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    nonisolated(unsafe) private var eventMonitor: Any?
    private var appState = NavSheetAppState()
    private var windowPatched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Flask"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func setupPopover() {
        let root = NavSheetRootView(
            onPickFolder: { [weak self] in self?.openFilePicker(attachedTo: .popover) },
            onPickFolderFromSheet: { [weak self] in self?.openFilePicker(attachedTo: .sheet) }
        ).environment(appState)
        hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = .preferredContentSize
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.animates = true
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.isHighlighted = true
        patchPopoverWindowClass()
        startEventMonitor()
    }

    // Patch the popover window's runtime class to AlwaysActivePopoverWindow
    // so isKeyWindow always returns true. Must run after show so the window
    // exists. Only needs to happen once — the same window is reused.
    private func patchPopoverWindowClass() {
        guard !windowPatched,
              let window = popover.contentViewController?.view.window
        else { return }
        object_setClass(window, AlwaysActivePopoverWindow.self)
        windowPatched = true
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Global event monitor
    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func stopEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    private var sheetWindow: NSWindow? {
        guard let pop = popoverWindow else { return nil }
        return pop.childWindows?.first(where: { $0.isVisible && $0 !== pop })
    }

    // MARK: - File picker
    enum PickerTarget { case popover, sheet }

    func openFilePicker(attachedTo target: PickerTarget) {
        let window: NSWindow?
        switch target {
        case .popover: window = popoverWindow
        case .sheet:   window = sheetWindow ?? popoverWindow
        }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = target == .sheet ? "Pick folder from inside sheet" : "Select a folder"
        panel.prompt = "Select"
        appState.overlayCount += 1
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.appState.overlayCount -= 1
            guard response == .OK, let url = panel.url else { return }
            switch target {
            case .popover: self?.appState.pickedFolderPath = url.path
            case .sheet:   self?.appState.sheetPickedFolderPath = url.path
            }
        }
    }
}

extension NavSheetAppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }
    func popoverDidShow(_ notification: Notification) {
        // Window now exists — patch if not done yet.
        patchPopoverWindowClass()
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        appState.overlayCount == 0
    }
    func popoverDidClose(_ notification: Notification) {
        setButtonHighlight(false)
        stopEventMonitor()
    }
}

// MARK: - Root view

struct NavSheetRootView: View {
    @Environment(NavSheetAppState.self) private var appState
    let onPickFolder: () -> Void
    let onPickFolderFromSheet: () -> Void

    var body: some View {
        switch appState.route {
        case .main:
            NavSheetMainView()
                .environment(appState)
                .task {
                    await MainActor.run { appState.taskFireCount += 1 }
                    print("[NavSheetSpike] .task fired (count=\(appState.taskFireCount)) - should be 1")
                }
        case .settings:
            NavSheetSettingsView(onPickFolder: onPickFolder, onPickFolderFromSheet: onPickFolderFromSheet)
                .environment(appState)
        }
    }
}

// MARK: - Main view

struct NavSheetMainView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Nav + Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Counter (persists on hide)") {
                HStack {
                    Text("\(appState.counter)").monospacedDigit().frame(minWidth: 24)
                    Spacer()
                    Button("+1") { appState.counter += 1 }
                }
            }

            GroupBox("TextField (persists on hide)") {
                TextField("Type here...", text: $appState.text)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox(".task fire count") {
                Text("\(appState.taskFireCount)x").monospacedDigit()
                if appState.taskFireCount > 1 {
                    Text("FAIL: fired more than once - view recreated")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("PASS: fired once")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            Button("Go to Settings") { appState.route = .settings }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Settings view

struct NavSheetSettingsView: View {
    @Environment(NavSheetAppState.self) private var appState
    let onPickFolder: () -> Void
    let onPickFolderFromSheet: () -> Void

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Settings counter (persists on hide)") {
                HStack {
                    Text("\(appState.settingsCounter)").monospacedDigit().frame(minWidth: 24)
                    Spacer()
                    Button("+1") { appState.settingsCounter += 1 }
                }
            }

            GroupBox("Toggle (persists on hide)") {
                Toggle("Enable something", isOn: $appState.settingsToggle)
            }

            GroupBox(".sheet (with alert + picker inside)") {
                Button("Open sheet...") { appState.showSettingsSheet = true }
                Label(
                    appState.showSettingsSheet ? "Sheet is open" : "Sheet is closed",
                    systemImage: appState.showSettingsSheet ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(appState.showSettingsSheet ? .green : .secondary)
                .font(.caption)
            }
            .anchoredSheet(isPresented: $appState.showSettingsSheet, overlayCount: $appState.overlayCount) {
                NavSheetSheetView(onPickFolder: onPickFolderFromSheet)
                    .environment(appState)
            }

            GroupBox("File picker (from settings)") {
                Button("Choose folder...") { onPickFolder() }
                if !appState.pickedFolderPath.isEmpty {
                    Text(appState.pickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No folder picked yet").font(.caption).foregroundStyle(.secondary)
                }
            }

            Button("Back") { appState.route = .main }
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Sheet view

struct NavSheetSheetView: View {
    @Environment(NavSheetAppState.self) private var appState
    let onPickFolder: () -> Void

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Settings Sheet").font(.headline)

            GroupBox("Sheet counter") {
                HStack {
                    Text("\(appState.sheetCounter)").monospacedDigit().frame(minWidth: 24)
                    Spacer()
                    Button("+1") { appState.sheetCounter += 1 }
                }
            }

            GroupBox("Alert from sheet") {
                Button("Show error alert") { appState.showSheetAlert = true }
                Text("Alert should appear, sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error alert shown from inside a sheet.")
            }

            GroupBox("File picker from sheet") {
                Button("Choose folder...") { onPickFolder() }
                if !appState.sheetPickedFolderPath.isEmpty {
                    Text(appState.sheetPickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No folder picked from sheet yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Picker attaches to the sheet window itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("Dismiss") { appState.showSettingsSheet = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

// MARK: - AnchoredSheet (NavSheetSpike variant)

extension View {
    func anchoredSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        overlayCount: Binding<Int>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(NavAnchoredSheetModifier(
            isPresented: isPresented,
            overlayCount: overlayCount,
            sheetContent: content
        ))
    }
}

private struct NavAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var overlayCount: Int
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                overlayCount = max(0, overlayCount - 1)
            }, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    overlayCount += 1
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else { return }
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            }
        }
    }
}
