// NavSheetSpike.swift
// RunBotSpike - spike/swiftui-nav-sheet branch
//
// Proof of concept for NSPopover + SwiftUI navigation + .sheet + file picker
// in a .accessory (menu bar) app.
//
// ARCHITECTURE:
// - @main is here. NSApplicationDelegateAdaptor wires NavSheetAppDelegate.
// - All app state lives in NavSheetAppState (@Observable).
// - Navigation is a route enum on appState — no NavigationStack.
//
// DISMISS STRATEGY:
// NSPopover in a .accessory app uses a nonactivatingPanel window, so
// .transient never reliably fires. Instead:
//   - .behavior = .applicationDefined (AppKit never auto-closes)
//   - A global NSEvent monitor fires on every outside click → performClose()
//   - NSWorkspace.didActivateApplicationNotification closes on Cmd+Tab /
//     clicking into another app; self-activation (e.g. after NSOpenPanel
//     closes) is ignored via NSRunningApplication.current guard
//   - popoverShouldClose returns false when overlayCount > 0, blocking
//     dismissal while a sheet or file picker is open
//   - overlayCount is managed explicitly
//
// ACTIVE APPEARANCE:
// NSApp.activate(ignoringOtherApps: true) is called on every openPopover().
// This promotes the app to key/active so AppKit renders all controls in their
// active state. Same mechanism as production (makeKeyForTextInput in main).
//
// SHEET ANCHORING:
// SwiftUI .sheet() creates a borderless child NSWindow. AnchoredSheet walks
// NSApp.windows to find it and calls addChildWindow(_:ordered:) so it stays
// attached to the popover window.
//
// FILE PICKER:
// NSOpenPanel.beginSheetModal(for: window) attaches the picker as a sheet,
// making it visible in window.sheets. overlayCount blocks outside-click
// dismiss while either a .sheet or picker is open.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import AppKit
import SwiftUI

// MARK: - Logging

private func log(_ tag: String, _ msg: String) {
    print("[NavSheet][\(tag)] \(msg)")
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
    var overlayCount: Int = 0 {
        didSet { log("State", "overlayCount \(oldValue) -> \(overlayCount)") }
    }
}

// MARK: - AppDelegate

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    nonisolated(unsafe) private var eventMonitor: Any?
    private var workspaceObserver: (any NSObjectProtocol)?
    private var appState = NavSheetAppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate", "applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Flask"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        log("StatusItem", "set up")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            log("Popover", "togglePopover -> closing")
            popover.performClose(nil)
        } else {
            log("Popover", "togglePopover -> opening")
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
        log("Popover", "configured behavior=.applicationDefined")
    }

    // MARK: - Workspace observer (close on app-switch)

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard self.popover.isShown else { return }
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard activated != NSRunningApplication.current else {
                log("WorkspaceObserver", "self-activation (e.g. after panel close), ignoring")
                return
            }
            log("WorkspaceObserver", "other app activated (\(activated?.localizedName ?? "?")) -> performClose")
            self.popover.performClose(nil)
        }
        log("WorkspaceObserver", "installed")
    }

    private func openPopover() {
        guard let button = statusItem.button else {
            log("Popover", "openPopover: no status button, aborting")
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Promote to key/active so controls render in active state.
        // Same as main branch makeKeyForTextInput().
        NSApp.activate(ignoringOtherApps: true)
        button.isHighlighted = true
        log("Popover", "shown + activated, button.isHighlighted=true")
        startEventMonitor()
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
        log("StatusItem", "isHighlighted=\(on)")
    }

    // MARK: - Global event monitor (outside click)

    private func startEventMonitor() {
        guard eventMonitor == nil else {
            log("EventMonitor", "already running, skipping")
            return
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            log("EventMonitor", "outside click type=\(event.type.rawValue) -> performClose")
            self?.popover.performClose(nil)
        }
        log("EventMonitor", "started")
    }

    private func stopEventMonitor() {
        guard let m = eventMonitor else {
            log("EventMonitor", "stopEventMonitor: already nil")
            return
        }
        NSEvent.removeMonitor(m)
        eventMonitor = nil
        log("EventMonitor", "stopped")
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
        let label = target == .popover ? "popover" : "sheet"
        let window: NSWindow?
        switch target {
        case .popover: window = popoverWindow
        case .sheet:   window = sheetWindow ?? popoverWindow
        }
        guard let window else {
            log("FilePicker", "[\(label)] no window found, aborting")
            return
        }
        log("FilePicker", "[\(label)] opening panel attached to \(NSStringFromClass(type(of: window)))")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = target == .sheet ? "Pick folder from inside sheet" : "Select a folder"
        panel.prompt = "Select"
        appState.overlayCount += 1
        log("FilePicker", "[\(label)] beginSheetModal overlayCount=\(appState.overlayCount)")
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.appState.overlayCount -= 1
            log("FilePicker", "[\(label)] closed response=\(response.rawValue) overlayCount=\(self?.appState.overlayCount ?? -1)")
            guard response == .OK, let url = panel.url else { return }
            log("FilePicker", "[\(label)] picked=\(url.path)")
            switch target {
            case .popover: self?.appState.pickedFolderPath = url.path
            case .sheet:   self?.appState.sheetPickedFolderPath = url.path
            }
        }
    }
}

extension NavSheetAppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        log("Popover", "popoverWillShow")
        setButtonHighlight(true)
    }
    func popoverDidShow(_ notification: Notification) {
        let windowClass = popover.contentViewController?.view.window.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        log("Popover", "popoverDidShow window=\(windowClass)")
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let allow = appState.overlayCount == 0
        log("Popover", "popoverShouldClose -> \(allow) (overlayCount=\(appState.overlayCount))")
        return allow
    }
    func popoverDidClose(_ notification: Notification) {
        log("Popover", "popoverDidClose")
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
                    log("Task", ".task fired count=\(appState.taskFireCount) (should be 1)")
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
                    Button("+1") {
                        appState.counter += 1
                        log("MainView", "counter=\(appState.counter)")
                    }
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

            Button("Go to Settings") {
                log("Nav", "route: main -> settings")
                appState.route = .settings
            }
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
                    Button("+1") {
                        appState.settingsCounter += 1
                        log("SettingsView", "settingsCounter=\(appState.settingsCounter)")
                    }
                }
            }

            GroupBox("Toggle (persists on hide)") {
                Toggle("Enable something", isOn: $appState.settingsToggle)
                    .onChange(of: appState.settingsToggle) { _, v in
                        log("SettingsView", "toggle=\(v)")
                    }
            }

            GroupBox(".sheet (with alert + picker inside)") {
                Button("Open sheet...") {
                    log("SettingsView", "opening sheet")
                    appState.showSettingsSheet = true
                }
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
                Button("Choose folder...") {
                    log("SettingsView", "requesting file picker from popover")
                    onPickFolder()
                }
                if !appState.pickedFolderPath.isEmpty {
                    Text(appState.pickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No folder picked yet").font(.caption).foregroundStyle(.secondary)
                }
            }

            Button("Back") {
                log("Nav", "route: settings -> main")
                appState.route = .main
            }
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
                    Button("+1") {
                        appState.sheetCounter += 1
                        log("SheetView", "sheetCounter=\(appState.sheetCounter)")
                    }
                }
            }

            GroupBox("Alert from sheet") {
                Button("Show error alert") {
                    log("SheetView", "showing alert")
                    appState.showSheetAlert = true
                }
                Text("Alert should appear, sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {
                    log("SheetView", "alert dismissed")
                }
            } message: {
                Text("This is a test error alert shown from inside a sheet.")
            }

            GroupBox("File picker from sheet") {
                Button("Choose folder...") {
                    log("SheetView", "requesting file picker from sheet")
                    onPickFolder()
                }
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

            Button("Dismiss") {
                log("SheetView", "dismissed by user")
                appState.showSettingsSheet = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

// MARK: - AnchoredSheet

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
                log("AnchoredSheet", "onDismiss overlayCount=\(overlayCount)")
            }, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                log("AnchoredSheet", "isPresented -> \(newValue)")
                if newValue {
                    overlayCount += 1
                    log("AnchoredSheet", "overlayCount=\(overlayCount), scheduling anchorSheetWindow")
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            log("AnchoredSheet", "anchorSheetWindow: no nonactivatingPanel window found")
            return
        }
        log("AnchoredSheet", "popoverWindow=\(NSStringFromClass(type(of: popoverWindow)))")
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                log("AnchoredSheet", "addChildWindow class=\(NSStringFromClass(type(of: sheetWindow)))")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                log("AnchoredSheet", "anchorSheetWindow: no borderless+key window found")
            }
        }
    }
}
