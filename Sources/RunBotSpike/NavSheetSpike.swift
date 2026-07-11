// NavSheetSpike.swift
// RunBotSpike - spike/swiftui-nav-sheet branch
//
// Builds on Option 3 (NSPopover + @NSApplicationDelegateAdaptor).
//
// DISMISS STRATEGY:
// .behavior = .applicationDefined so AppKit never auto-closes.
// We close on popoverWindowDidResignKey UNLESS a sheet/picker is active
// (popoverWindow.sheets is non-empty, or a child window is visible).
// This means: click anywhere outside -> popover loses key -> closes.
// But: open a sheet/picker -> popover window is no longer key but sheets
// guard fires -> stays open.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import AppKit
import SwiftUI

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
}

// MARK: - AppDelegate

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var resignKeyObserver: NSObjectProtocol?
    private var appState = NavSheetAppState()

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
        popover.isShown ? closePopover() : openPopover()
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
        installResignKeyObserver()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    private var sheetWindow: NSWindow? {
        guard let pop = popoverWindow else { return nil }
        return pop.childWindows?.first(where: { $0.isVisible && $0 !== pop })
    }

    private var hasActiveOverlay: Bool {
        guard let pop = popoverWindow else { return false }
        if !pop.sheets.isEmpty { return true }
        if let children = pop.childWindows, !children.isEmpty { return true }
        return false
    }

    // MARK: - Resign-key observer
    // Wrap body in Task { @MainActor in } so the closure can legally
    // access @MainActor-isolated properties (popoverWindow, hasActiveOverlay,
    // closePopover). Without the Task wrapper Swift 6.2 treats the
    // NotificationCenter closure as Sendable/nonisolated and rejects those
    // accesses at compile time.
    private func installResignKeyObserver() {
        guard resignKeyObserver == nil else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let window = notification.object as? NSWindow,
                      window === self.popoverWindow else { return }
                guard !self.hasActiveOverlay else { return }
                self.closePopover()
            }
        }
    }

    private func removeResignKeyObserver() {
        if let o = resignKeyObserver {
            NotificationCenter.default.removeObserver(o)
            resignKeyObserver = nil
        }
    }

    // NOTE: no deinit — deinit on a @MainActor class is nonisolated in
    // Swift 6.2 and cannot synchronously call main-actor methods.
    // removeResignKeyObserver() is called from popoverDidClose instead.

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
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            switch target {
            case .popover: self?.appState.pickedFolderPath = url.path
            case .sheet:   self?.appState.sheetPickedFolderPath = url.path
            }
        }
    }
}

extension NavSheetAppDelegate: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool { true }
    func popoverDidClose(_ notification: Notification) { removeResignKeyObserver() }
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
            .anchoredSheet(isPresented: $appState.showSettingsSheet) {
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
