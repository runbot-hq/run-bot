// SheetPreservationSpike.swift
// RunBotSpike — spike/swiftui-lifecycle branch
//
// PURPOSE:
// Self-contained test for SwiftUI MenuBarExtra behaviour on macOS 26.
// Answers all 8 questions required before migrating AppDelegate → RunBotApp.
// See docs/spike-results.md for the test checklist.
// See issue #1987 for the migration context.
//
// HOW TO RUN:
//   swift run RunBotSpike
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none (zero RunBot modules imported)

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Entry point
// @main lives in Option3Spike.swift while Option 3 is under test.

struct SheetSpikeApp: App {
    @State private var appState = SpikeAppState()

    var body: some Scene {
        MenuBarExtra("\u{1F9EA} Spike", systemImage: "flask.fill") {
            SpikeRootView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App-level state (@Observable, owned by App struct)

@Observable
@MainActor
final class SpikeAppState {
    var navState: SpikeNavState = .main
    var showSettingsSheet: Bool = false
    var sheetDraftText: String = ""
    var taskStartCount: Int = 0
}

enum SpikeNavState {
    case main
    case settings
}

// MARK: - Root view

struct SpikeRootView: View {
    @Environment(SpikeAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            switch appState.navState {
            case .main:
                MainSpikeView()
                    .environment(appState)
            case .settings:
                SettingsSpikeView()
                    .environment(appState)
            }
        }
        .task {
            await MainActor.run { appState.taskStartCount += 1 }
            print("\u{1F535} [Spike] .task started (count=\(appState.taskStartCount)) — should only print ONCE")
            for await _ in AsyncStream<Void> { _ in } { }
        }
    }
}

// MARK: - Main view

struct MainSpikeView: View {
    @Environment(SpikeAppState.self) private var appState

    @State private var localCounter: Int = 0
    @State private var localText: String = ""
    @State private var showLocalSheet: Bool = false

    @State private var hostWindow: NSWindow?
    @State private var pickedFolderPath: String = ""
    @State private var outsideClickMonitor: Any?

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 14) {

            Text("MenuBarExtra Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Scenario 1 — View-local @State counter") {
                HStack {
                    Text("Counter: \(localCounter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { localCounter += 1 }
                }
                Text("Close + reopen. Counter should survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Scenario 2 — View-local TextField") {
                TextField("Type here...", text: $localText)
                    .textFieldStyle(.roundedBorder)
                Text("Close + reopen. Text should survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Scenario 3 — Sheet open across hide/show") {
                Button("Open local sheet") { showLocalSheet = true }
                Label(
                    showLocalSheet ? "Sheet IS open" : "Sheet is closed",
                    systemImage: showLocalSheet ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(showLocalSheet ? .green : .secondary)
                Text("Open sheet, click outside to close app, reopen.\nSheet should still be visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .anchoredSheet(isPresented: $showLocalSheet) {
                SheetSpikeView(parentText: $localText, isPresented: $showLocalSheet)
            }

            GroupBox("Scenario 6 — App-level sheet state") {
                Button("Open app-state sheet") { appState.showSettingsSheet = true }
                Label(
                    appState.showSettingsSheet ? "App sheet IS open" : "App sheet is closed",
                    systemImage: appState.showSettingsSheet ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(appState.showSettingsSheet ? .green : .secondary)
                Text("If Scenario 3 fails, this is the fallback.\nState lives on SpikeAppState (@Observable).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .anchoredSheet(isPresented: $appState.showSettingsSheet) {
                SheetSpikeView(parentText: $appState.sheetDraftText, isPresented: $appState.showSettingsSheet)
            }

            GroupBox("Scenario 7c — File picker (beginSheetModal + click guard)") {
                Button("Choose folder…") { pickFolder() }
                if !pickedFolderPath.isEmpty {
                    Text(pickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text("Click inside the picker. App should NOT dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            GroupBox("Scenario 5 — .task start count") {
                Text(".task started \(appState.taskStartCount)x")
                    .monospacedDigit()
                Text("Should be 1. If > 1, scene recreates on every open.")
                    .font(.caption)
                    .foregroundStyle(appState.taskStartCount > 1 ? .red : .secondary)
            }

            Button("Go to Settings") {
                appState.navState = .settings
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)

            Button("Close") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
        .background(WindowGrabber { w in
            if hostWindow == nil, let w { hostWindow = w }
        })
    }

    private func pickFolder() {
        guard let window = hostWindow else { return }
        installOutsideClickMonitor(for: window)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            removeOutsideClickMonitor()
            guard response == .OK, let url = panel.url else { return }
            pickedFolderPath = url.path
        }
    }

    private func installOutsideClickMonitor(for window: NSWindow) {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak window] _ in
            Task { @MainActor in
                guard let window else { return }
                guard !window.sheets.isEmpty else { return }
                window.makeKey()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

// MARK: - Settings view

struct SettingsSpikeView: View {
    @Environment(SpikeAppState.self) private var appState
    @State private var settingsCounter: Int = 0
    @State private var showChildSheet: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Settings")
                .font(.headline)

            GroupBox("Scenario 4 — Settings-local @State") {
                HStack {
                    Text("Counter: \(settingsCounter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { settingsCounter += 1 }
                }
                Text("Navigate away + back. Counter should survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Scenario 9 — Sheet from child (NavStack)") {
                Button("Open child sheet") { showChildSheet = true }
                Label(
                    showChildSheet ? "Child sheet IS open" : "Child sheet is closed",
                    systemImage: showChildSheet ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(showChildSheet ? .green : .secondary)
                Text("Verifies .sheet works from a child view inside the nav stack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .anchoredSheet(isPresented: $showChildSheet) {
                SheetSpikeView(parentText: .constant(""), isPresented: $showChildSheet)
            }

            Button("← Back") {
                appState.navState = .main
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Sheet view

struct SheetSpikeView: View {
    @Binding var parentText: String
    @Binding var isPresented: Bool

    @State private var sheetCounter: Int = 0
    @State private var sheetText: String = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Sheet is open")
                .font(.headline)

            GroupBox("Sheet-local @State") {
                HStack {
                    Text("Sheet counter: \(sheetCounter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { sheetCounter += 1 }
                }
                TextField("Sheet text", text: $sheetText)
                    .textFieldStyle(.roundedBorder)
                Text("Hide app (click outside), reopen.\nCounter + text should survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Parent binding") {
                Text("Parent text: \"\(parentText)\"")
                    .foregroundStyle(.secondary)
            }

            Button("Dismiss") { isPresented = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }
}

// MARK: - AnchoredSheet

extension View {
    func anchoredSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(AnchoredSheetModifier(isPresented: isPresented, sheetContent: content))
    }
}

private struct AnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                guard newValue else { return }
                Task { @MainActor in anchorSheetWindow() }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let menuBarWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else { return }

        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== menuBarWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                menuBarWindow.addChildWindow(sheetWindow, ordered: .above)
            }
        }
    }
}

// MARK: - WindowGrabber

final class NSWindowGrabber: NSView {
    var onWindow: (NSWindow?) -> Void
    init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }
    required init?(coder _: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
    }
}

struct WindowGrabber: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context _: Context) -> NSWindowGrabber { NSWindowGrabber(onWindow: onWindow) }
    func updateNSView(_ nsView: NSWindowGrabber, context _: Context) { nsView.onWindow = onWindow }
}
