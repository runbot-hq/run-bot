// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet branch
//
// PURPOSE:
// Tests whether MenuBarExtra(.window) can host a .sheet() whose Dismiss
// button closes ONLY the sheet, not the MenuBarExtra window.
//
// THE FIX: @Environment(\.dismiss) inside a separate named View struct.
// Already verified in RunBotSpike (spike/swiftui-lifecycle):
//   "@Environment(\.dismiss) resolves to the sheet’s own dismiss action
//    when used inside a .sheet — it does NOT bubble up to close the
//    MenuBarExtra window."
//
// @Binding + isPresented = false does NOT work — it does not scope the
// dismiss to the sheet and causes the host window to close.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none

import SwiftUI

@main
struct StatusBarSheetSpikeApp: App {
    var body: some Scene {
        MenuBarExtra("🧪 Sheet Spike", systemImage: "flask.fill") {
            SpikeContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

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
                Text("Increment → open sheet → dismiss. Counter must not reset.")
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

                Text("After Dismiss: only the sheet closes.\n🧪 icon + this window must stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .sheet(isPresented: $isSheetPresented) {
            SheetView()
        }
    }
}

// @Environment(\.dismiss) scopes dismiss to this sheet only.
// Do NOT use @Binding + isPresented = false — that closes the host window.
struct SheetView: View {
    @Environment(\.dismiss) private var dismiss
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

            Text("Tap Dismiss.\nOnly THIS sheet should close.\n🧪 icon + MenuBarExtra window must survive.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
        .frame(minWidth: 300)
    }
}
