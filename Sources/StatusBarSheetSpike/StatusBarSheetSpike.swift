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
    @State private var isSheetPresented: Bool = false
    @State private var counter: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MenuBarExtra Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

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
            .sheet(isPresented: $isSheetPresented) {
                SheetView(isPresented: $isSheetPresented)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            SheetDismissGuardView(isSheetPresented: $isSheetPresented)
        )
    }
}

// MARK: - Sheet content

struct SheetView: View {
    // Explicit @Binding avoids @Environment(\.dismiss) which on macOS can
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
                Text("Resets on dismiss — expected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Tap Dismiss.\nOnly THIS sheet should close.\nThe MenuBarExtra window and 🧪 icon must survive.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

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

// MARK: - SheetDismissGuardView
//
// Zero-size NSViewRepresentable that installs a SheetDismissGuard on the
// MenuBarExtra's host NSWindow. Runs on every SwiftUI re-render so the
// guard always sees the latest isSheetPresented value.

private struct SheetDismissGuardView: NSViewRepresentable {
    @Binding var isSheetPresented: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        SheetDismissGuard.guard(for: window).track(isSheetPresented: isSheetPresented, in: window)
    }

    func makeCoordinator() -> Void { }
}

// MARK: - SheetDismissGuard
//
// Problem: dismissing a sheet inside MenuBarExtra (.window style) makes
// AppKit interpret the focus change as an outside-click, firing
// NSWindow.willCloseNotification on the host window and collapsing the
// whole popover.
//
// Fix: detect the isSheetPresented true→false transition, set
// suppressNextHide, and re-show the window if it tries to close while
// the flag is set. Mirrors PopoverLifecycleCoordinator in RunBot target.
//
// Swift 6 notes:
// - Associated-object key is a nonisolated(unsafe) UInt8 static var
//   (not a String) to avoid UnsafeRawPointer-from-String warnings.
// - observer is nonisolated(unsafe) so the nonisolated deinit can call
//   removeObserver without a Sendable violation.
// - The NotificationCenter callback runs on queue: .main, so
//   MainActor.assumeIsolated is safe there.

@MainActor
private final class SheetDismissGuard: NSObject {
    private static nonisolated(unsafe) var associatedKey: UInt8 = 0

    static func `guard`(for window: NSWindow) -> SheetDismissGuard {
        if let existing = objc_getAssociatedObject(window, &associatedKey) as? SheetDismissGuard {
            return existing
        }
        let g = SheetDismissGuard(window: window)
        objc_setAssociatedObject(window, &associatedKey, g, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return g
    }

    private weak var window: NSWindow?
    private var suppressNextHide = false
    private var wasPresented = false
    // nonisolated(unsafe): only ever written on MainActor; read in deinit
    // which is nonisolated. The value is a simple token — no data race risk.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    private init(window: NSWindow) {
        self.window = window
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees we are on the main thread.
            MainActor.assumeIsolated {
                self?.handleWindowWillClose()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func track(isSheetPresented: Bool, in window: NSWindow) {
        // true → false transition = sheet is being dismissed
        if wasPresented && !isSheetPresented {
            suppressNextHide = true
        }
        wasPresented = isSheetPresented
    }

    private func handleWindowWillClose() {
        guard suppressNextHide else { return }
        suppressNextHide = false
        DispatchQueue.main.async { [weak window] in
            window?.orderFront(nil)
        }
    }
}
