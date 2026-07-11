// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet branch
//
// PURPOSE:
// Verifies that a pure-SwiftUI (no AppDelegate) macOS status bar app can
// present a .sheet() INSIDE the MenuBarExtra window itself, and that
// tapping Dismiss closes only the sheet — NOT the MenuBarExtra window
// and NOT the status-bar icon.
//
// THE FIX (no AppKit hacks needed):
//   1. Attach .sheet() to the outermost view in the root content struct.
//   2. Put sheet content in a separate named View struct.
//   Inline/anonymous sheet content causes SwiftUI's dismiss to walk up
//   the responder chain and close the host window. A named child struct
//   scopes the dismiss environment correctly.
//
// Source: https://stackoverflow.com/questions/78835562
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// THEN:
// 1. Click the 🧪 flask icon in the menu bar.
// 2. Increment the counter.
// 3. Click "Open Sheet" — sheet slides up inside the same window.
// 4. Click "Dismiss" — only the sheet closes.
//    Counter must be unchanged. 🧪 icon stays in menu bar.
// 5. Click the icon again — it still works.
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none

import SwiftUI

// MARK: - Entry point

@main
struct StatusBarSheetSpikeApp: App {
    var body: some Scene {
        MenuBarExtra("🧪 Sheet Spike", systemImage: "flask.fill") {
            SpikeContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Root content (lives inside MenuBarExtra)

struct SpikeContentView: View {
    @State private var isSheetPresented = false
    @State private var counter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MenuBarExtra Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("State survives sheet dismiss") {
                HStack {
                    Text("Counter: \(counter)").monospacedDigit()
                    Spacer()
                    Button("+1") { counter += 1 }
                }
                Text("Increment, open sheet, dismiss. Counter must not reset.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            GroupBox("Sheet inside MenuBarExtra") {
                Button("Open Sheet") { isSheetPresented = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Label(
                    isSheetPresented ? "Sheet IS open" : "Sheet is closed",
                    systemImage: isSheetPresented ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(isSheetPresented ? .green : .secondary)

                Text("After Dismiss: only the sheet closes.\nThis window and the 🧪 icon must stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        // KEY: .sheet() is on the outermost view in this struct,
        // not on a nested child (GroupBox, Button, etc.).
        .sheet(isPresented: $isSheetPresented) {
            // KEY: content is a separate named View struct, not an
            // inline closure with views directly inside.
            SheetView(isPresented: $isSheetPresented)
        }
    }
}

// MARK: - Sheet content
//
// KEY: this is a separate named View struct.
// If the sheet content were inline (e.g. VStack { ... } directly inside
// the .sheet closure), SwiftUI's dismiss environment would walk up the
// responder chain to the host NSWindow and close the entire MenuBarExtra
// window. A named struct creates a new SwiftUI environment boundary that
// scopes dismiss to the sheet only.

struct SheetView: View {
    // Explicit @Binding instead of @Environment(\.dismiss).
    // Belt-and-suspenders: keeps dismiss fully local to this struct.
    @Binding var isPresented: Bool
    @State private var sheetCounter = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet is open ✅").font(.headline)

            GroupBox("Sheet-local state") {
                HStack {
                    Text("Sheet counter: \(sheetCounter)").monospacedDigit()
                    Spacer()
                    Button("+1") { sheetCounter += 1 }
                }
                Text("Resets on dismiss — expected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Tap Dismiss.\nOnly THIS sheet should close.\nThe MenuBarExtra window and 🧪 icon must survive.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Dismiss") { isPresented = false }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 300)
    }
}
