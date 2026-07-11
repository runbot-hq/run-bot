// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet-swiftui branch
//
// PURPOSE:
// Minimal, self-contained proof that a pure SwiftUI status-bar app can
// present a .sheet and dismiss it WITHOUT hiding the status-bar item or
// the app process.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears (🧪 Spike).
//   2. Click the icon → window opens.
//   3. Click "Open Sheet" → sheet slides in.
//   4. Click "Dismiss Sheet" → ONLY the sheet disappears.
//      The MenuBarExtra window stays open.
//      The status-bar icon stays in the menu bar.
//      The process does NOT terminate.
//   5. Click the icon again → window reopens without restarting.
//
// REQUIREMENTS: macOS 13+, Swift 6
// DEPENDENCIES: none (zero RunBot modules imported)

import SwiftUI

// MARK: - Entry point

@main
struct StatusBarSheetApp: App {
    var body: some Scene {
        MenuBarExtra("\u{1F9EA} Spike", systemImage: "flask.fill") {
            ContentView()
        }
        // .window style is required for reliable .sheet behaviour inside a
        // MenuBarExtra. The default .menu style does not support sheets.
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Main content

struct ContentView: View {
    @State private var isShowingSheet = false
    // A counter to confirm the window is NOT recreated when the sheet dismisses.
    @State private var openCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("StatusBar Sheet Spike")
                .font(.headline)

            Divider()

            // ── Scenario A: dismiss() closes only the sheet ──────────────
            GroupBox("Scenario A — Sheet dismiss") {
                Button("Open Sheet") {
                    isShowingSheet = true
                }
                Label(
                    isShowingSheet ? "Sheet IS open" : "Sheet is closed",
                    systemImage: isShowingSheet
                        ? "checkmark.circle.fill"
                        : "xmark.circle"
                )
                .foregroundStyle(isShowingSheet ? .green : .secondary)

                Text("After dismissing the sheet:\n• This window stays open\n• Status-bar icon stays\n• App does NOT quit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sheet(isPresented: $isShowingSheet) {
                SheetView(isPresented: $isShowingSheet)
            }

            // ── Scenario B: window-open count stays at 1 ────────────────
            GroupBox("Scenario B — Window not recreated") {
                Text("Window open count: \(openCount)")
                    .monospacedDigit()
                Text("Should stay at 1 across sheet open/dismiss cycles.")
                    .font(.caption)
                    .foregroundStyle(openCount > 1 ? .red : .secondary)
            }
            .onAppear { openCount += 1 }

            Divider()

            Button("Quit App") {
                // Explicit quit — the only way to terminate the process.
                // Dismissing the sheet MUST NOT reach here.
                NSApplication.shared.terminate(nil)
            }
            .foregroundStyle(.red)
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Sheet

struct SheetView: View {
    // Explicit binding instead of @Environment(\.dismiss).
    // On macOS, @Environment(\.dismiss) inside a MenuBarExtra panel can bubble
    // up past the sheet and close the entire MenuBarExtra window.
    // Using the binding directly is the safe, verified pattern.
    @Binding var isPresented: Bool

    // Sheet-local state — survives multiple open/dismiss cycles because
    // isPresented = false only hides the sheet, it does not destroy the view.
    @State private var dismissCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet is open")
                .font(.headline)

            GroupBox("Dismiss counter") {
                Text("Dismissed \(dismissCount) time(s)")
                    .monospacedDigit()
                Text("Reopen the sheet and confirm the count persists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Dismiss Sheet") {
                dismissCount += 1
                isPresented = false
                // ↑ Sets the binding to false → only the sheet presentation
                // is removed. The MenuBarExtra window and status-bar item
                // are completely unaffected.
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
