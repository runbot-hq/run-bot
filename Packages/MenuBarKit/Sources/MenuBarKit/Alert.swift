// Alert.swift
// MenuBarKit
//
// Adds mbkAlert ViewModifier for gate-managed alert presentation.
//
// PROBLEM:
//   SwiftUI's .alert() is a system-modal presentation that AppKit manages
//   independently of NSWindow child relationships. It does not need the
//   window-anchoring logic of MBKAnchoredSheet, but it still needs to arm
//   MBKOverlayGate.hasActiveOverlay so the outside-click monitor does not
//   close the popover while the alert is on screen.
//
// GATE:
//   MBKOverlayGate is read from the SwiftUI environment (@Environment).
//   No overlayGate: parameter is needed at call sites.
//
// CONCURRENT OVERLAY SAFETY:
//   The one acknowledged exception to single-overlay usage is an alert
//   presented while a sheet is already open.
//   - On alert appear: always set gate = true.
//   - On alert dismiss: only clear gate = false if the gate was not already
//     armed by a concurrent overlay when the alert appeared.
//   This is tracked via @State Bool `gateWasArmedByConcurrentOverlay`.
//   If a future scenario requires full reference counting, replace the Bool
//   with an Int and use increment/decrement.
//
// USAGE:
//   .mbkAlert("Title", isPresented: $flag) { Button("OK", role: .cancel) {} }
//
//   With a message:
//   .mbkAlert("Title", isPresented: $flag) {
//       Button("OK", role: .cancel) {}
//   } message: {
//       Text("Something went wrong.")
//   }

import SwiftUI

// MARK: - View extension

/// View extension providing `mbkAlert` modifier overloads.
/// Reads `MBKOverlayGate` from the SwiftUI environment — inject it at the root
/// view via `.environment(overlayGate)` and no `overlayGate:` parameter is needed.
public extension View {

    /// Presents an alert and manages the overlay gate for its lifetime.
    /// Drop-in replacement for SwiftUI’s `.alert(_:isPresented:actions:)`.
    ///
    /// - Warning: Requires `MBKOverlayGate` to be present in the SwiftUI environment.
    ///   If not injected via `.environment(overlayGate)` at the root view,
    ///   SwiftUI will raise a fatal error at runtime.
    func mbkAlert<A: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        modifier(MBKAlertModifier(
            title: title,
            isPresented: isPresented,
            actions: actions,
            message: { EmptyView() }
        ))
    }

    /// Presents an alert with a message and manages the overlay gate for its lifetime.
    /// Drop-in replacement for SwiftUI’s `.alert(_:isPresented:actions:message:)`.
    ///
    /// - Warning: Requires `MBKOverlayGate` to be present in the SwiftUI environment.
    ///   If not injected via `.environment(overlayGate)` at the root view,
    ///   SwiftUI will raise a fatal error at runtime.
    func mbkAlert<A: View, M: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) -> some View {
        modifier(MBKAlertModifier(
            title: title,
            isPresented: isPresented,
            actions: actions,
            message: message
        ))
    }
}

// MARK: - Modifier

/// ViewModifier that wraps SwiftUI’s `.alert()` and gates `MBKOverlayGate`
/// (read from environment) for the full alert lifetime.
///
/// This type is internal. Use the `.mbkAlert(...)` methods on `View` instead.
/// Direct construction is not useful: `MBKAlertModifier` depends on
/// `@Environment(MBKOverlayGate.self)` and can only function when embedded
/// in a SwiftUI view hierarchy that has the gate injected.
struct MBKAlertModifier<A: View, M: View>: ViewModifier {
    /// The alert title string.
    let title: String
    /// Binding that controls whether the alert is currently presented.
    @Binding var isPresented: Bool
    /// Alert action buttons.
    let actions: () -> A
    /// Optional secondary message view shown below the title.
    let message: () -> M

    /// The gate that blocks popover dismiss while the alert is live.
    /// Resolved from the SwiftUI environment — must be injected at the root view.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// Tracks whether the gate was already armed by a concurrent overlay
    /// (e.g. a sheet) when this alert appeared.
    /// If `true` on dismiss, the gate belongs to the concurrent overlay
    /// and must not be cleared here.
    @State private var gateWasArmedByConcurrentOverlay = false

    /// Creates the modifier.
    /// - Parameters:
    ///   - title: The alert title string.
    ///   - isPresented: Binding that controls presentation.
    ///   - actions: Alert action buttons.
    ///   - message: Secondary message view shown below the title.
    init(
        title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) {
        self.title = title
        self._isPresented = isPresented
        self.actions = actions
        self.message = message
    }

    /// Applies the alert and gate-management logic.
    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented, actions: actions, message: message)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    // Record whether the gate was already armed so the dismiss
                    // path knows whether to clear it.
                    gateWasArmedByConcurrentOverlay = overlayGate.hasActiveOverlay
                    overlayGate.hasActiveOverlay = true
                    mbkLog("Alert", "appeared — gate armed (concurrent=\(gateWasArmedByConcurrentOverlay))")
                } else {
                    // Only clear the gate if we were the ones who armed it.
                    // If a concurrent sheet was live when the alert appeared,
                    // the gate belongs to the sheet — do not clear.
                    if !gateWasArmedByConcurrentOverlay {
                        overlayGate.hasActiveOverlay = false
                        mbkLog("Alert", "dismissed — gate cleared")
                    } else {
                        mbkLog("Alert", "dismissed — gate preserved (concurrent overlay still live)")
                    }
                }
            }
    }
}
