// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet branch
//
// ROOT CAUSE:
// .sheet opens a second NSPanel. When that panel becomes key, MenuBarExtra
// treats it as an "outside click" and closes its own window. This happens
// regardless of @Binding vs @Environment(\.dismiss) and regardless of
// whether the sheet content is a separate View struct.
//
// THE FIX: anchoredSheet(_:)
// After isPresented flips true, find the new NSPanel SwiftUI created and
// call menuBarWindow.addChildWindow(sheetPanel, ordered: .above).
// Child windows share a focus group with their parent, so focus moving to
// the sheet is no longer treated as an outside-click. Panel stays open.
//
// Standard SwiftUI .sheet API is preserved. No fake overlay, no NSWindowDelegate.
//
// ALSO: use @Binding to dismiss, NOT @Environment(\.dismiss).
// On MenuBarExtra, dismiss() bubbles past the sheet and closes the window.
//
// Ported from: spike/statusbar-sheet-swiftui
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none

import SwiftUI
import AppKit

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
        // Use anchoredSheet, not plain .sheet.
        // See AnchoredSheetModifier below for why.
        .anchoredSheet(isPresented: $isSheetPresented) {
            SheetView(isPresented: $isSheetPresented)
        }
    }
}

// @Binding dismiss — NOT @Environment(\.dismiss).
// On MenuBarExtra, @Environment(\.dismiss) bubbles past the sheet
// and closes the host window.
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

            Text("Tap Dismiss.\nOnly THIS sheet should close.\n🧪 icon + MenuBarExtra window must survive.")
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

// MARK: - anchoredSheet
//
// Wraps .sheet and parents the NSPanel SwiftUI creates to the MenuBarExtra
// window via addChildWindow(_:ordered:).
//
// Why this works:
// Child windows share a focus group with their parent. When the sheet
// NSPanel becomes key, AppKit no longer treats it as an outside-click
// on the MenuBarExtra window.
//
// Sheet detection: after isPresented flips true, find an NSWindow that:
//   - is NOT the MenuBarExtra window (which has .nonactivatingPanel style)
//   - has .borderless styleMask (SwiftUI sheet panels are borderless)
//   - is currently key (just became active)

extension View {
    func anchoredSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
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
                print("[AnchoredSheet] anchoring \(sheetWindow) to \(menuBarWindow)")
                menuBarWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                print("[AnchoredSheet] sheet window not found — anchor skipped")
            }
        }
    }
}
