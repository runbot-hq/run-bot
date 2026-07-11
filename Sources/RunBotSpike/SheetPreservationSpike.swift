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

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Entry point

@main
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
    @State private var showFilePicker: Bool = false

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
            .sheet(isPresented: $showLocalSheet) {
                SheetSpikeView(parentText: $localText)
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
            .sheet(isPresented: $appState.showSettingsSheet) {
                SheetSpikeView(parentText: $appState.sheetDraftText)
            }

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
            .sheet(isPresented: $showChildSheet) {
                SheetSpikeView(parentText: .constant(""))
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

// MARK: - Sheet view

struct SheetSpikeView: View {
    @Binding var parentText: String
    // @Environment(\.dismiss) resolves to the sheet's own dismiss action
    // when used inside a .sheet — it does NOT bubble up to close the MenuBarExtra window.
    @Environment(\.dismiss) private var dismiss

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
                Text("Editing the parent TextField should reflect here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Scenario 8: Check the app window still has\nrounded corners while this sheet is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}
