// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet branch
//
// PURPOSE:
// Tests whether MenuBarExtra(.window) can host a .sheet() whose Dismiss
// button closes ONLY the sheet and not the MenuBarExtra window.
//
// APPROACH: NSWindowDelegate.windowShouldClose interception.
// willClose fires AFTER the window is already gone.
// windowShouldClose fires BEFORE — returning false blocks the close.
// We only block it during the one runloop turn when a sheet dismiss
// triggers the spurious close. Genuine outside-click closes pass through.
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none

import SwiftUI
import AppKit

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

// MARK: - Root content

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

                Text("After Dismiss: only the sheet closes.\nThis window + 🧪 icon must stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
        .sheet(isPresented: $isSheetPresented) {
            SheetView(isPresented: $isSheetPresented)
        }
        // Installs NSWindowDelegate on the host window to intercept
        // the spurious windowShouldClose that fires on sheet dismiss.
        .background(SheetDismissGuardView(isSheetPresented: isSheetPresented))
    }
}

// MARK: - Sheet

struct SheetView: View {
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

            Text("Tap Dismiss.\nOnly THIS sheet should close.\nThe MenuBarExtra window + 🧪 icon must survive.")
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

// MARK: - SheetDismissGuardView
//
// Zero-size NSViewRepresentable. Its only job is to hand the current
// isSheetPresented value to SheetDismissGuard on every SwiftUI render
// so the delegate can detect the true→false transition.

private struct SheetDismissGuardView: NSViewRepresentable {
    let isSheetPresented: Bool   // plain value, not a Binding

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        SheetDismissGuard.install(on: window, isSheetPresented: isSheetPresented)
    }

    func makeCoordinator() -> Void { }
}

// MARK: - SheetDismissGuard (NSWindowDelegate)
//
// Intercepts windowShouldClose before the close happens.
//
// Timeline on Dismiss tap:
//   1. isPresented = false fires
//   2. SwiftUI re-renders SpikeContentView with isSheetPresented=false
//   3. updateNSView fires — guard detects true→false, sets suppressNextClose
//   4. AppKit fires windowShouldClose on the host window
//   5. We return false — close is blocked
//   6. suppressNextClose is cleared
//
// Timeline on genuine outside-click:
//   1. No isSheetPresented transition — suppressNextClose stays false
//   2. windowShouldClose — we return true — window closes normally

@MainActor
private final class SheetDismissGuard: NSObject, NSWindowDelegate {
    private static nonisolated(unsafe) var key: UInt8 = 0

    static func install(on window: NSWindow, isSheetPresented: Bool) {
        let guard_: SheetDismissGuard
        if let existing = objc_getAssociatedObject(window, &key) as? SheetDismissGuard {
            guard_ = existing
        } else {
            guard_ = SheetDismissGuard()
            objc_setAssociatedObject(window, &key, guard_, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.delegate = guard_
        }
        guard_.update(isSheetPresented: isSheetPresented)
    }

    private var suppressNextClose = false
    private var wasPresented = false

    func update(isSheetPresented: Bool) {
        if wasPresented && !isSheetPresented {
            // Sheet is being dismissed — arm the suppressor.
            suppressNextClose = true
        }
        wasPresented = isSheetPresented
    }

    // NSWindowDelegate — called BEFORE the window closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if suppressNextClose {
            suppressNextClose = false
            return false   // block this close: it's the sheet-dismiss side-effect
        }
        return true        // allow: genuine outside-click or quit
    }
}
