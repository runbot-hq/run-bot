// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet-swiftui branch
//
// PURPOSE:
// Tests the pattern from https://stackoverflow.com/a/78843009
//
// KEY INSIGHT FROM THAT ANSWER:
//   1. @Environment(\.dismiss) inside a .sheet on a MenuBarExtra window
//      dismisses the WINDOW, not the sheet. Do NOT use it.
//   2. Setting the isPresented binding to false correctly dismisses
//      only the sheet.
//   3. Sheet content must live in a SEPARATE View struct, not inline.
//
// Confirmed working on macOS 13.6.8 by the answer author.
// The click-to-close on macOS 14/15 may be a framework regression.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears.
//   2. Click icon -> main panel shows.
//   3. Click "Present Sheet" -> sheet appears.
//   4. Click "Falsify" -> ONLY the sheet closes.
//      Panel stays open. Icon stays. App does NOT quit.
//   5. Repeat 5x.
//   6. Also verify: clicking anywhere inside the sheet does NOT close the panel.
//
// REQUIREMENTS: macOS 13+, Swift 6
// DEPENDENCIES: none

import SwiftUI

// MARK: - Entry point

@main
struct MenuBarTestApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "circle")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Content (mirrors the SO answer exactly)

struct ContentView: View {
    @State private var sheetDisplayed: Bool = false

    var body: some View {
        Text("Menu Bar Window")
            .padding()
        Button("Present Sheet") {
            sheetDisplayed = true
        }
        .padding()
        .frame(minWidth: 300, minHeight: 200)
        .sheet(isPresented: $sheetDisplayed) {
            // Sheet content is a SEPARATE struct — per the SO answer,
            // this is required for correct dismiss scoping.
            SheetContent(sheetDisplayed: $sheetDisplayed)
        }
        .task(id: sheetDisplayed) {
            print("sheetDisplayed: \(sheetDisplayed)")
        }
    }
}

// MARK: - Sheet content in its own struct
//
// IMPORTANT: @Environment(\.dismiss) is intentionally NOT used here.
// Per https://stackoverflow.com/a/78843009, calling dismiss() from
// inside a sheet on a MenuBarExtra window closes the WINDOW, not the sheet.
// Setting the binding to false is the correct approach.

struct SheetContent: View {
    @Binding var sheetDisplayed: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet")
                .font(.headline)

            Text("Clicking anywhere here should NOT close the panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Falsify (dismiss sheet)") {
                sheetDisplayed = false  // correct: dismisses sheet only
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)

            // Left here intentionally to show the broken pattern:
            // Button("Dismiss (closes window)") { dismiss() }
        }
        .frame(minWidth: 200, minHeight: 160)
        .padding()
    }
}
