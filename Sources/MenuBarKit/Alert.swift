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
    /// Drop-in replacement for SwiftUI's `.alert(_:isPresented:actions:)`.
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
    /// Drop-in replacement for SwiftUI's `.alert(_:isPresented:actions:message:)`.
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

/// ViewModifier that wraps SwiftUI's `.alert()` and gates `MBKOverlayGate`
/// (read from environment) for the full alert lifetime.
public struct MBKAlertModifier<A: View, M: View>: ViewModifier {
    public let title: String
    @Binding public var isPresented: Bool
    public let actions: () -> A
    public let message: () -> M

    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var gateWasArmedByConcurrentOverlay = false

    public init(
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

    public func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented, actions: actions, message: message)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    gateWasArmedByConcurrentOverlay = overlayGate.hasActiveOverlay
                    overlayGate.hasActiveOverlay = true
                    mbkLog("Alert", "appeared — gate armed (concurrent=\(gateWasArmedByConcurrentOverlay))")
                } else {
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
