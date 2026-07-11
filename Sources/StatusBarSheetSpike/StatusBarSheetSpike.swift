// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet branch
//
// PURPOSE:
// Verifies the answer to the question:
//   "Can a pure-SwiftUI status bar app open a sheet whose Dismiss button
//    closes ONLY the sheet — not the MenuBarExtra window, not the status
//    bar icon, not the app?"
//
// ANSWER: Yes — by keeping the .sheet() inside a separate Window scene
// and using openWindow(id:) from MenuBarExtra to trigger it.
// Pressing Dismiss sets isPresented = false. The MenuBarExtra window and
// the status-bar icon remain untouched.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// THEN:
// 1. Click the flask icon in the menu bar.
// 2. Click "Open Sheet".
// 3. A sheet slides up in the panel window.
// 4. Click "Dismiss" inside the sheet.
// 5. ✅ Only the sheet disappears. The panel window stays open.
//    Click the flask icon again to verify the icon + window still work.
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none

import SwiftUI

// MARK: - Entry point

@main
struct StatusBarSheetSpikeApp: App {
    // @Environment(\..openWindow) is injected by SwiftUI for use in the
    // MenuBarExtra content closure.
    var body: some Scene {
        // ── 1. Status-bar item ───────────────────────────────────────────
        // The MenuBarExtra content only triggers openWindow.
        // NO .sheet() here — that is the key to the fix.
        MenuBarExtra("\u{1F9EA} Sheet Spike", systemImage: "flask.fill") {
            MenuBarTriggerView()
        }
        .menuBarExtraStyle(.window)

        // ── 2. Panel window — hosts the actual UI + sheet ────────────────
        // This is a regular SwiftUI Window scene. .sheet() behaves normally
        // here: Dismiss closes only the sheet; the window (and MenuBarExtra)
        // remain alive.
        Window("Sheet Spike Panel", id: "sheet-spike-panel") {
            PanelView()
        }
        .defaultSize(width: 320, height: 1) // height is auto-fitted by content
    }
}

// MARK: - MenuBar trigger (thin — only opens the Window)

struct MenuBarTriggerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Text("Status Bar Sheet Spike")
                .font(.headline)

            Divider()

            Button("Open Panel") {
                // Opens (or focuses) the Window scene above.
                // The MenuBarExtra window is unaffected by anything that
                // happens inside that Window scene.
                openWindow(id: "sheet-spike-panel")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .foregroundStyle(.red)
        }
        .padding(12)
        .frame(width: 240)
    }
}

// MARK: - Panel (Window scene content)
//
// This is where the .sheet() lives. Because this view is inside a
// Window scene — not inside MenuBarExtra's popover — SwiftUI's
// standard sheet lifecycle applies: dismiss only collapses the sheet.

struct PanelView: View {
    @State private var isSheetPresented: Bool = false
    @State private var counter: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Panel Window")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // ── Counter — persists across sheet open/close ───────────────
            GroupBox("State survives sheet") {
                HStack {
                    Text("Counter: \(counter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { counter += 1 }
                }
                Text("Increment, open + dismiss the sheet. Counter must not reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ── Sheet trigger ────────────────────────────────────────────
            GroupBox("Sheet") {
                Button("Open Sheet") { isSheetPresented = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Label(
                    isSheetPresented ? "Sheet IS open" : "Sheet is closed",
                    systemImage: isSheetPresented
                        ? "checkmark.circle.fill"
                        : "xmark.circle"
                )
                .foregroundStyle(isSheetPresented ? .green : .secondary)

                Text("After dismissing: only the sheet closes.\nThe panel + status-bar icon stay alive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // ✅ .sheet() attached to a view inside a Window scene — works correctly.
            .sheet(isPresented: $isSheetPresented) {
                SheetView(isPresented: $isSheetPresented)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Sheet content
//
// Uses an explicit @Binding instead of @Environment(\.dismiss).
// On macOS, @Environment(\.dismiss) inside a MenuBarExtra panel can bubble
// up and close the whole popover. With an explicit binding we control
// exactly what gets set to false — nothing else is touched.

struct SheetView: View {
    // Explicit binding — setting this to false is the ONLY side effect of Dismiss.
    @Binding var isPresented: Bool

    @State private var sheetCounter: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet is open ✅")
                .font(.headline)

            GroupBox("Sheet-local state") {
                HStack {
                    Text("Sheet counter: \(sheetCounter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { sheetCounter += 1 }
                }
                Text("This counter resets on dismiss (sheet is recreated).\nThat is expected and correct.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Tap Dismiss below.\nOnly this sheet should close.\nThe Panel window and the 🧪 menu-bar icon must survive.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // ── THE KEY BUTTON ───────────────────────────────────────────
            // Sets isPresented = false.
            // Effect: sheet slides away. Nothing else changes.
            Button("Dismiss") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 300)
    }
}
