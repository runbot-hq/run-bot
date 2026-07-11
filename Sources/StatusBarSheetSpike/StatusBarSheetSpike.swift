// StatusBarSheetSpike.swift
// StatusBarSheetSpike — spike/statusbar-sheet branch
//
// PURPOSE:
// Verifies that a pure-SwiftUI (no AppDelegate) macOS status bar app can
// present a .sheet() INSIDE the MenuBarExtra window itself, and that
// tapping Dismiss closes only the sheet — NOT the MenuBarExtra window
// and NOT the status-bar icon.
//
// KEY QUESTION ANSWERED:
//   Does Dismiss hide the whole MenuBarExtra window or just the sheet?
//
// HOW TO RUN:
//   swift run StatusBarSheetSpike
//
// THEN:
// 1. Click the 🧪 flask icon in the menu bar.
// 2. The MenuBarExtra window opens. Increment the counter.
// 3. Click "Open Sheet".
// 4. A sheet slides up INSIDE the same MenuBarExtra window.
// 5. Click "Dismiss".
// 6. ✅ Only the sheet closes. The MenuBarExtra window stays open.
//    The counter value must be unchanged.
//    The 🧪 icon stays in the menu bar.
// 7. Open the window again by clicking the icon — it still works.
//
// REQUIREMENTS: macOS 26+, Swift 6.2
// DEPENDENCIES: none (zero RunBot modules)

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

// MARK: - Root content (lives inside MenuBarExtra)

struct SpikeContentView: View {
    // Sheet flag lives here — view-local @State inside MenuBarExtra.
    // This is the scenario that breaks naively: setting this to true
    // opens the sheet, but tapping Dismiss fires an outside-click event
    // that also closes the MenuBarExtra window unless suppressed.
    @State private var isSheetPresented: Bool = false
    @State private var counter: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MenuBarExtra Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // ── Counter — must survive sheet open/close ──────────────────
            GroupBox("State survives sheet dismiss") {
                HStack {
                    Text("Counter: \(counter)")
                        .monospacedDigit()
                    Spacer()
                    Button("+1") { counter += 1 }
                }
                Text("Increment, open sheet, dismiss. Counter must not reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ── Sheet trigger ────────────────────────────────────────────
            GroupBox("Sheet inside MenuBarExtra") {
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

                Text("After Dismiss: only the sheet closes.\nThis window and the 🧪 icon must stay alive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // ✅ .sheet() is attached HERE — directly inside MenuBarExtra.
            // The SheetDismissGuard (below) suppresses the window-close that
            // would otherwise fire when Dismiss is tapped.
            .sheet(isPresented: $isSheetPresented) {
                SheetView(isPresented: $isSheetPresented)
            }
        }
        .padding(16)
        .frame(width: 320)
        // Install the suppress-hide guard whenever the sheet is open.
        .background(
            SheetDismissGuardView(isSheetPresented: $isSheetPresented)
        )
    }
}

// MARK: - Sheet content

struct SheetView: View {
    // Explicit @Binding — avoids @Environment(\.dismiss) which on macOS can
    // bubble up through the responder chain and close the popover window.
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
                Text("This resets on dismiss — expected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Tap Dismiss.\nOnly THIS sheet should close.\nThe MenuBarExtra window and 🧪 icon must survive.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // ── THE KEY BUTTON ──────────────────────────────────────────
            // Sets isPresented = false. SheetDismissGuard suppresses the
            // window-close that AppKit fires as a side-effect.
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

// MARK: - SheetDismissGuard
//
// The problem: when a sheet inside a MenuBarExtra (.window style) is
// dismissed, AppKit interprets the focus change as an outside-click and
// sends a close event to the NSWindow hosting the MenuBarExtra content.
// Without a guard, the entire popover window closes alongside the sheet.
//
// The fix (mirrors PopoverLifecycleCoordinator in the main RunBot target):
//   1. Watch the isSheetPresented binding.
//   2. When it transitions true → false, set suppressNextHide = true.
//   3. Observe NSWindow.willCloseNotification on the host window.
//   4. If a close fires while suppressed, call orderFront to re-show the
//      window and clear the flag.
//
// This is implemented as a zero-size UIRepresentable so it can access
// the NSWindow from inside the SwiftUI view hierarchy.

private struct SheetDismissGuardView: NSViewRepresentable {
    @Binding var isSheetPresented: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.frame = .zero
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Install (or update) the guard on the host window.
        guard let window = nsView.window else { return }
        let guard_ = SheetDismissGuard.guard(for: window)
        guard_.track(isSheetPresented: isSheetPresented, in: window)
    }

    func makeCoordinator() -> Void { }
}

@MainActor
private final class SheetDismissGuard: NSObject {
    // One guard per NSWindow, stored in objc associated storage.
    private static var key = "SheetDismissGuard"

    static func `guard`(for window: NSWindow) -> SheetDismissGuard {
        if let existing = objc_getAssociatedObject(window, &key) as? SheetDismissGuard {
            return existing
        }
        let g = SheetDismissGuard(window: window)
        objc_setAssociatedObject(window, &key, g, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return g
    }

    private weak var window: NSWindow?
    private var suppressNextHide = false
    private var wasPresented = false
    private var observer: NSObjectProtocol?

    private init(window: NSWindow) {
        self.window = window
        super.init()
        // Observe willClose on this specific window.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowWillClose()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // Called from updateNSView on every SwiftUI re-render.
    func track(isSheetPresented: Bool, in window: NSWindow) {
        // Detect the true → false transition = sheet is being dismissed.
        if wasPresented && !isSheetPresented {
            suppressNextHide = true
        }
        wasPresented = isSheetPresented
    }

    private func handleWindowWillClose() {
        guard suppressNextHide else { return }
        suppressNextHide = false
        // Re-show the window on the next run-loop tick so the close can
        // finish its internal bookkeeping before we reverse it.
        DispatchQueue.main.async { [weak window] in
            window?.orderFront(nil)
        }
    }
}
