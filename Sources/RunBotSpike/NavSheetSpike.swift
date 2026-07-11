// NavSheetSpike.swift
// RunBotSpike - spike/swiftui-nav-sheet branch
//
// Builds on Option 3 (NSPopover + @NSApplicationDelegateAdaptor).
//
// DISMISS STRATEGY:
// .behavior = .transient — AppKit auto-dismisses on outside click.
// popoverShouldClose blocks dismissal while appState.overlayCount > 0.
// overlayCount is incremented/decremented explicitly by AnchoredSheet
// and by the file picker callbacks — no childWindows inspection (stale).
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
    // Incremented when a sheet or picker opens, decremented when it closes.
    // popoverShouldClose returns false while this is > 0.
    var overlayCount: Int = 0
}

// MARK: - AppDelegate

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
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
        popover.isShown ? popover.performClose(nil) : openPopover()
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
        popover.behavior = .transient
        popover.delegate = self
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        appState.overlayCount == 0
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

// MARK: - AnchoredSheet
// Overload used in NavSheetSpike: takes an overlayCount binding so the
// popover delegate knows whether a sheet is active without inspecting
// childWindows (which are never cleaned up by SwiftUI).

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
