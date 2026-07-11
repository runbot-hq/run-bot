// StatusBarSheetSpike.swift
// StatusBarSheetSpike -- spike/statusbar-sheet-swiftui branch
//
// PURPOSE:
// Proves that a real SwiftUI .sheet works inside a .window-style
// MenuBarExtra on macOS 14+ with one AppKit fix:
//   window.hidesOnDeactivate = false
//
// ROOT CAUSE OF THE BUG (macOS 14+):
//   MenuBarExtra's NSWindow has hidesOnDeactivate = true by default.
//   When .sheet creates a second NSWindow, the MenuBarExtra window
//   loses key status. macOS interprets that as "clicked outside" and
//   closes the entire panel -- before the user touches anything.
//
// THE FIX:
//   Find the NSWindow backing the MenuBarExtra (via
//   NSWindow.didBecomeKeyNotification) and set hidesOnDeactivate = false
//   once. That single property change stops macOS from auto-closing the
//   panel on deactivation. Everything else is pure SwiftUI.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// WHAT TO VERIFY:
//   1. Click the status-bar icon -- window opens.
//   2. Click "Open Sheet" -- sheet appears OVER the window.
//   3. Click anywhere inside the sheet -- window does NOT close.
//   4. Click "Dismiss" -- only the sheet closes.
//      Window stays open. Icon stays. App does NOT quit.
//   5. Repeat 5x.
//
// REQUIREMENTS: macOS 13+, Swift 6
// DEPENDENCIES: none

import SwiftUI
import AppKit

// MARK: - Entry point

@main
struct StatusBarSheetApp: App {
    var body: some Scene {
        MenuBarExtra("Spike", systemImage: "flask.fill") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Content

struct ContentView: View {
    @State private var isShowingSheet = false
    @State private var counter = 0
    @State private var dismissCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("StatusBar Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Scenario A -- Real .sheet") {
                Button("Open Sheet") { isShowingSheet = true }
                Text("Sheet must open over this window. Clicking inside sheet must NOT close the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sheet(isPresented: $isShowingSheet) {
                SheetView(dismissCount: $dismissCount, isPresented: $isShowingSheet)
            }

            GroupBox("Scenario B -- State survives") {
                HStack {
                    Text("Counter: \(counter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { counter += 1 }
                }
                Text("Increment, open sheet, dismiss. Counter must survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit App") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 300)
        // THE FIX: runs once when the window first becomes key.
        // Finds this view's NSWindow and disables the auto-hide-on-deactivate
        // behaviour that causes the MenuBarExtra panel to close when .sheet
        // opens a second NSWindow and steals key status.
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            window.hidesOnDeactivate = false
        }
    }
}

// MARK: - Sheet

struct SheetView: View {
    @Binding var dismissCount: Int
    // Use explicit binding, NOT @Environment(\.dismiss) --
    // on macOS @Environment(\.dismiss) bubbles up and can close the
    // MenuBarExtra window instead of just the sheet.
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet is open")
                .font(.headline)

            GroupBox("Dismiss counter") {
                Text("Dismissed \(dismissCount) time(s)")
                    .monospacedDigit()
                Text("Reopen the sheet -- counter persists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The window and status-bar icon are still alive. Dismiss closes ONLY this sheet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Dismiss") {
                dismissCount += 1
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
