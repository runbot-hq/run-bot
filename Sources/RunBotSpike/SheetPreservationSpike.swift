// SheetPreservationSpike.swift
// RunBotSpike — spike/swiftui-lifecycle branch
//
// PURPOSE:
// Self-contained test for SwiftUI MenuBarExtra behaviour on macOS 26.
// Answers all 9 questions required before migrating AppDelegate → RunBotApp.
// See docs/spike-results.md for the test checklist.
// See issue #1987 for the migration context.
//
// HOW TO RUN:
//   swift run RunBotSpike
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none (zero RunBot modules imported)
//
// KEY DESIGN DECISION — no .sheet inside MenuBarExtra:
// Presenting a .sheet directly inside a MenuBarExtra(.window) causes macOS to
// treat the sheet as a separate window. When that sheet appears/dismisses, the
// app briefly "loses focus", triggering MenuBarExtra's hide-on-deactivate and
// collapsing the popover. This is a known macOS/SwiftUI bug (FB13290249).
//
// FIX: Use a dedicated Window scene for anything that was previously a sheet.
// Open it imperatively via @Environment(\.openWindow). The MenuBarExtra never
// sees a focus change because the Window scene is a sibling scene, not a child
// of the MenuBarExtra content view tree.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Window scene IDs

enum SpikeWindowID {
    static let settings = "spike-settings"
    static let childSheet = "spike-child-sheet"
}

// MARK: - Entry point

@main
struct SheetSpikeApp: App {
    // @State on the App struct — NOT on a view.
    // This is the proposed AppState ownership model.
    // If state survives close/reopen when owned here → architecture is valid.
    @State private var appState = SpikeAppState()

    var body: some Scene {
        // ── Scene 1: MenuBarExtra — NO .sheet modifiers anywhere inside ──
        MenuBarExtra("\u{1F9EA} Spike", systemImage: "flask.fill") {
            SpikeRootView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        // ── Scene 2: Settings window (replaces .sheet) ───────────────────
        // Opened via openWindow(id:) from inside MenuBarExtra content.
        // Lives as a sibling scene so MenuBarExtra never loses focus.
        Window("Spike Settings", id: SpikeWindowID.settings) {
            SettingsWindowView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 420)

        // ── Scene 3: Child sheet window (Scenario 9) ─────────────────────
        Window("Child Sheet", id: SpikeWindowID.childSheet) {
            ChildSheetWindowView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 320)
    }
}

// MARK: - App-level state (@Observable, owned by App struct)

@Observable
@MainActor
final class SpikeAppState {
    var navState: SpikeNavState = .main

    // Text shared between the MenuBarExtra and the Settings window,
    // via @Observable — mirrors the AppState binding pattern in RunBot.
    var sharedText: String = ""

    // Counter to detect .task re-execution (Scenario 5)
    var taskStartCount: Int = 0
}

enum SpikeNavState {
    case main
    case settings
}

// MARK: - Root view

struct SpikeRootView: View {
    @Environment(SpikeAppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

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
        // Scenario 5: .task lifecycle — watch console for repeat prints.
        // Expected: prints ONCE at app launch, never again on close/reopen.
        .task {
            await MainActor.run { appState.taskStartCount += 1 }
            print("\u{1F535} [Spike] .task started (count=\(appState.taskStartCount)) — should only print ONCE")
            let stream = AsyncStream<Void> { _ in }
            for await _ in stream { }
        }
    }
}

// MARK: - Main view

struct MainSpikeView: View {
    @Environment(SpikeAppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var localCounter: Int = 0
    @State private var showFilePicker: Bool = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 14) {

            Text("MenuBarExtra Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // ── Scenario 1: View-local @State integer ────────────────────
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

            // ── Scenario 2: Shared @Observable text ──────────────────────
            GroupBox("Scenario 2 — Shared @Observable TextField") {
                TextField("Type here...", text: $appState.sharedText)
                    .textFieldStyle(.roundedBorder)
                Text("Text lives on SpikeAppState. Close + reopen. Should survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ── Scenario 3: Open Settings as Window scene (no .sheet) ────
            // This is the fix for MenuBarExtra hide-on-dismiss.
            // openWindow opens a sibling scene — MenuBarExtra stays visible.
            GroupBox("Scenario 3 — Settings via Window scene") {
                Button("Open Settings window") {
                    openWindow(id: SpikeWindowID.settings)
                }
                Text("MenuBarExtra must NOT hide when Settings opens or closes.\nThis replaces the broken .sheet-inside-MenuBarExtra pattern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ── Scenario 7: .fileImporter — does picker dismiss app? ─────
            GroupBox("Scenario 7 — .fileImporter") {
                Button("Open file picker") { showFilePicker = true }
                Text("Click inside the picker. App should NOT dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.folder]
            ) { result in
                print("\u{1F535} [Spike] fileImporter result: \(result)")
            }

            Divider()

            // ── Scenario 5: .task lifecycle readout ─────────────────────
            GroupBox("Scenario 5 — .task start count") {
                Text(".task started \(appState.taskStartCount)x")
                    .monospacedDigit()
                Text("Should be 1. If > 1, scene recreates on every open.")
                    .font(.caption)
                    .foregroundStyle(appState.taskStartCount > 1 ? .red : .secondary)
            }

            // ── Navigation to settings ───────────────────────────────────
            Button("Go to Settings (in-popover nav)") {
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
    }
}

// MARK: - Settings view (in-popover nav — Scenario 4)

struct SettingsSpikeView: View {
    @Environment(SpikeAppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var settingsCounter: Int = 0

    var body: some View {
        VStack(spacing: 14) {
            Text("Settings (in-popover)")
                .font(.headline)

            // ── Scenario 4: Nav-state @State preservation ────────────────
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

            // ── Scenario 9: Child sheet as Window scene ───────────────────
            GroupBox("Scenario 9 — Child window from nav view") {
                Button("Open child window") {
                    openWindow(id: SpikeWindowID.childSheet)
                }
                Text("Opens via Window scene — MenuBarExtra must stay visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("\u{2190} Back") {
                appState.navState = .main
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Settings Window view (Scenario 3 — sibling Window scene)

struct SettingsWindowView: View {
    @Environment(SpikeAppState.self) private var appState

    @State private var windowCounter: Int = 0
    @State private var windowText: String = ""

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Settings Window")
                .font(.headline)

            GroupBox("Window-local @State") {
                HStack {
                    Text("Counter: \(windowCounter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { windowCounter += 1 }
                }
                TextField("Window text...", text: $windowText)
                    .textFieldStyle(.roundedBorder)
                Text("Close + reopen this window. State resets — window-local\n@State is NOT preserved across Window scene open/close.\nPersistent data must live on SpikeAppState.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Shared @Observable text (from MenuBarExtra)") {
                Text("\"\(appState.sharedText)\"")
                    .foregroundStyle(.secondary)
                Text("Should reflect what you typed in Scenario 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ── Scenario 8: MenuBarExtra rounded corners ─────────────────
            Text("Scenario 8: While this window is open,\ncheck the MenuBarExtra still has rounded corners.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Child Sheet Window view (Scenario 9)

struct ChildSheetWindowView: View {
    @State private var childCounter: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Child Window")
                .font(.headline)

            GroupBox("Scenario 9 — Child window @State") {
                HStack {
                    Text("Counter: \(childCounter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { childCounter += 1 }
                }
                Text("MenuBarExtra must remain visible while this is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}
