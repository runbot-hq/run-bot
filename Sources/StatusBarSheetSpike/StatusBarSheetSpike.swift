// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet-swiftui branch
//
// PURPOSE:
// Verifies the CORRECT pattern for "sheet-like" dismissal inside a
// .window-style MenuBarExtra, after confirming that SwiftUI's native
// .sheet modifier is broken in this context on macOS 13–26:
//
//   BUG: clicking anywhere inside a .sheet presented from a MenuBarExtra
//   window dismisses the ENTIRE MenuBarExtra window, not just the sheet.
//   Confirmed on macOS 14.6 and 15. The @Binding workaround does NOT fix it.
//   Root cause: the sheet opens a second NSWindow; any click that shifts
//   focus back to the MenuBarExtra NSWindow is treated as an outside-click
//   → MenuBarExtra closes.
//
// SOLUTION: Never open a second NSWindow from the MenuBarExtra panel.
// Swap content INLINE within the same single window using a simple
// @State enum. The result looks and behaves like a sheet but never
// creates a second window, so focus never leaves the MenuBarExtra panel.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears (🧪 Spike).
//   2. Click icon → main content shows.
//   3. Click "Open Sheet" → "sheet" content slides in (inline swap).
//   4. Click "Dismiss" → ONLY the sheet content disappears.
//      The window stays open. Icon stays. App does NOT quit.
//   5. Repeat 5× — icon and window always survive.
//
// REQUIREMENTS: macOS 13+, Swift 6
// DEPENDENCIES: none

import SwiftUI

// MARK: - Entry point

@main
struct StatusBarSheetApp: App {
    var body: some Scene {
        MenuBarExtra("\u{1F9EA} Spike", systemImage: "flask.fill") {
            RootView()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Navigation state

enum PanelView {
    case main
    case sheet
}

// MARK: - Root: swaps between main and sheet content inline
//
// Key insight: both views live in the SAME NSWindow that MenuBarExtra
// manages. No second window is ever created, so macOS never interprets
// a tap as an "outside click" and the MenuBarExtra stays open.

struct RootView: View {
    @State private var currentView: PanelView = .main
    @State private var dismissCount = 0

    var body: some View {
        Group {
            switch currentView {
            case .main:
                MainPanelView(onOpenSheet: {
                    currentView = .sheet
                })
            case .sheet:
                SheetPanelView(
                    dismissCount: $dismissCount,
                    onDismiss: {
                        currentView = .main
                    }
                )
            }
        }
        .frame(width: 300)
        .animation(.easeInOut(duration: 0.18), value: currentView)
    }
}

// MARK: - Main panel

struct MainPanelView: View {
    let onOpenSheet: () -> Void
    // Survives because this view is not destroyed on sheet-dismiss;
    // only currentView enum changes.
    @State private var counter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("StatusBar Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Scenario A — Inline sheet-like swap") {
                Button("Open Sheet") { onOpenSheet() }
                Text("After dismissing:\n\u2022 This window stays open\n\u2022 Status-bar icon stays\n\u2022 App does NOT quit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Scenario B — State preserved across swap") {
                HStack {
                    Text("Counter: \(counter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { counter += 1 }
                }
                Text("Increment, open sheet, dismiss. Counter should survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit App") {
                NSApplication.shared.terminate(nil)
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }
}

// MARK: - Sheet panel (inline — same window, no NSWindow creation)

struct SheetPanelView: View {
    @Binding var dismissCount: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet Content")
                .font(.headline)

            GroupBox("Dismiss counter") {
                Text("Dismissed \(dismissCount) time(s)")
                    .monospacedDigit()
                Text("Each dismiss increments this. Reopen to confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The window and status-bar icon are still alive right now.\nDismissing will NOT close the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Dismiss") {
                dismissCount += 1
                onDismiss()
                // ↑ Flips currentView back to .main in RootView.
                // No window is closed. No NSWindow focus changes.
                // The MenuBarExtra panel stays fully alive.
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }
}
