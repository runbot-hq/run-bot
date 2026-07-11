// NavSheetSpike.swift
// RunBotSpike — spike/swiftui-nav-sheet branch
//
// Builds on Option 3 (NSPopover + @NSApplicationDelegateAdaptor).
//
// TESTS:
// 1. Navigation: main → settings → back. Does nav state survive hide/show?
// 2. Settings sheet: open .sheet from settings view. Does it work?
// 3. State persistence: counter + text field values survive hide/show.
//
// HOW TO RUN:
//   swift run RunBotSpike
//   (@main is on NavSheetApp below — Option3Spike.swift has @main commented out)
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
    // Navigation
    var route: NavSheetRoute = .main

    // Main view state
    var counter: Int = 0
    var text: String = ""

    // Settings view state
    var settingsCounter: Int = 0
    var settingsToggle: Bool = false
    var showSettingsSheet: Bool = false

    // Sheet state (survives sheet dismiss + popover hide)
    var sheetCounter: Int = 0
    var sheetText: String = ""

    // Observability probe
    var taskFireCount: Int = 0
}

// MARK: - AppDelegate

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    nonisolated(unsafe) private var outsideClickMonitor: Any?
    private var appState = NavSheetAppState()

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
        popover.isShown ? closePopover() : openPopover()
    }

    private func setupPopover() {
        let root = NavSheetRootView()
            .environment(appState)
        hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = .preferredContentSize
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 320, height: 300)
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

extension NavSheetAppDelegate: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool { true }
    func popoverDidClose(_ notification: Notification) { removeOutsideClickMonitor() }
}

// MARK: - Root view (switches on nav state)

struct NavSheetRootView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        switch appState.route {
        case .main:
            NavSheetMainView()
                .environment(appState)
                .task {
                    await MainActor.run { appState.taskFireCount += 1 }
                    print("[NavSheetSpike] .task fired (count=\(appState.taskFireCount)) — should be 1")
                }
        case .settings:
            NavSheetSettingsView()
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
                    Text("\(appState.counter)")
                        .monospacedDigit()
                        .frame(minWidth: 24)
                    Spacer()
                    Button("+1") { appState.counter += 1 }
                }
            }

            GroupBox("TextField (persists on hide)") {
                TextField("Type here…", text: $appState.text)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox(".task fire count") {
                Text("\(appState.taskFireCount)x")
                    .monospacedDigit()
                Text(appState.taskFireCount > 1 ? "❌ Fired more than once — view recreated" : "✅ Fired once")
                    .font(.caption)
                    .foregroundStyle(appState.taskFireCount > 1 ? .red : .green)
            }

            Button("Go to Settings →") {
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

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Settings counter (persists on hide)") {
                HStack {
                    Text("\(appState.settingsCounter)")
                        .monospacedDigit()
                        .frame(minWidth: 24)
                    Spacer()
                    Button("+1") { appState.settingsCounter += 1 }
                }
            }

            GroupBox("Toggle (persists on hide)") {
                Toggle("Enable something", isOn: $appState.settingsToggle)
            }

            GroupBox(".sheet from settings") {
                Button("Open sheet…") { appState.showSettingsSheet = true }
                Label(
                    appState.showSettingsSheet ? "Sheet is open" : "Sheet is closed",
                    systemImage: appState.showSettingsSheet
                        ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(appState.showSettingsSheet ? .green : .secondary)
                .font(.caption)
            }
            .anchoredSheet(isPresented: $appState.showSettingsSheet) {
                NavSheetSheetView()
                    .environment(appState)
            }

            Button("← Back") {
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

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Settings Sheet")
                .font(.headline)

            GroupBox("Sheet counter (persists across hide/dismiss)") {
                HStack {
                    Text("\(appState.sheetCounter)")
                        .monospacedDigit()
                        .frame(minWidth: 24)
                    Spacer()
                    Button("+1") { appState.sheetCounter += 1 }
                }
            }

            GroupBox("Sheet text (persists across hide/dismiss)") {
                TextField("Type in sheet…", text: $appState.sheetText)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Hide the app while this sheet is open.\nReopen — sheet should still be here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Dismiss") { appState.showSettingsSheet = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 300)
    }
}

// MARK: - AnchoredSheet (port from spike/statusbar-sheet-swiftui PR #2033)
//
// Uses addChildWindow so the sheet window shares a focus group with the
// popover window. The popover never sees an outside-click when the sheet
// is key. Identical approach to the working solution in PR #2033.

extension View {
    func anchoredSheet<C: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        modifier(AnchoredSheetModifier2(isPresented: isPresented, sheetContent: content))
    }
}

private struct AnchoredSheetModifier2<C: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> C

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, new in
                guard new else { return }
                Task { @MainActor in anchorSheet() }
            }
    }

    @MainActor
    private func anchorSheet() {
        guard let parent = NSApp.windows.first(where: {
            !$0.styleMask.contains(.nonactivatingPanel) && $0.isVisible
        }) else { return }
        DispatchQueue.main.async {
            guard let sheet = NSApp.windows.first(where: {
                $0 !== parent && $0.isKeyWindow
            }) else { return }
            parent.addChildWindow(sheet, ordered: .above)
        }
    }
}
