// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet-swiftui branch
//
// PURPOSE:
// Verifies that a real SwiftUI .sheet works inside a .window-style
// MenuBarExtra without closing the panel, on macOS 14/15.
//
// ROOT CAUSE OF THE BUG:
// .sheet opens a second NSWindow (an NSPanel). When that panel becomes
// key, the MenuBarExtra treats it as an "outside click" and closes its
// own window. This happens even with the SO binding-only pattern
// (https://stackoverflow.com/a/78843009) on macOS 14+.
//
// THE FIX:
// After the sheet binding flips to true, find the new NSPanel and call:
//   menuBarWindow.addChildWindow(sheetPanel, ordered: .above)
// Child windows share a focus group with their parent. Focus moving to
// the sheet is no longer treated as an outside-click. Panel stays open.
//
// Standard SwiftUI .sheet API is preserved. No AppDelegate, no fake overlay.
// Binding is set to false to dismiss (NOT @Environment(\.dismiss) which
// bubbles past the sheet and closes the window).
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// WHAT TO VERIFY:
//   1. Status-bar icon appears.
//   2. Click icon -> panel shows.
//   3. Click "Present Sheet" -> real .sheet appears over the panel.
//      Panel is visible behind it.
//   4. Click "Dismiss Sheet" or press Escape -> ONLY sheet closes.
//      Panel stays open. Icon stays. App does NOT quit.
//   5. Repeat 5x. task log should only print once per open.
//
// REQUIREMENTS: macOS 13+, Swift 6
// DEPENDENCIES: none

import AppKit
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

// MARK: - Content

struct ContentView: View {
    @State private var sheetDisplayed = false
    @State private var counter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Menu Bar Window")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Real .sheet test") {
                Button("Present Sheet") { sheetDisplayed = true }
                Text("Panel must stay visible behind the sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("State check") {
                HStack {
                    Text("Counter: \(counter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { counter += 1 }
                }
                Text("Increment, open sheet, dismiss. Must survive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit App") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(minWidth: 300, minHeight: 200)
        .anchoredSheet(isPresented: $sheetDisplayed) {
            SheetContent(sheetDisplayed: $sheetDisplayed)
        }
        .task(id: sheetDisplayed) {
            print("sheetDisplayed: \(sheetDisplayed)")
        }
    }
}

// MARK: - Sheet content
//
// Uses binding to dismiss, NOT @Environment(\.dismiss).
// On MenuBarExtra, dismiss() bubbles past the sheet and closes the window.

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

            Button("Dismiss Sheet") {
                sheetDisplayed = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .frame(minWidth: 200, minHeight: 160)
        .padding()
    }
}

// MARK: - AnchoredSheet
//
// Wraps .sheet and parents the NSPanel SwiftUI creates to the MenuBarExtra
// window via addChildWindow(_:ordered:).
//
// Detection: after isPresented flips true, find an NSWindow that:
//   - is NOT the MenuBarExtra window (.nonactivatingPanel)
//   - has .borderless styleMask  (SwiftUI sheet panels are borderless)
//   - is currently key           (just became active)

extension View {
    func anchoredSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(AnchoredSheetModifier(isPresented: isPresented, sheetContent: content))
    }
}

private struct AnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                guard newValue else { return }
                Task { @MainActor in anchorSheetWindow() }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let menuBarWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            print("[AnchoredSheet] MenuBarExtra window not found")
            return
        }

        // One run-loop pass to let SwiftUI finish creating the sheet NSPanel.
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== menuBarWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                print("[AnchoredSheet] anchoring sheet window: \(sheetWindow)")
                menuBarWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                print("[AnchoredSheet] sheet window not found — anchor skipped")
                NSApp.windows.forEach {
                    print("  window: \($0) styleMask: \($0.styleMask) isKey: \($0.isKeyWindow)")
                }
            }
        }
    }
}
