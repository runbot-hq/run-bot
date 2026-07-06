// WindowGrabber.swift
// RunBot
//
// Captures the NSWindow that hosts a SwiftUI view the moment the view is
// inserted into the window hierarchy. Used to obtain a reliable NSWindow
// reference for `beginSheetModal(for:)` without racing against keyWindow
// changes.
//
// Usage:
//   .background(WindowGrabber { window in self.hostWindow = window })
//
// #1195 — required for NSOpenPanel.beginSheetModal inside NSPopover.

import AppKit
import RunBotCore
import SwiftUI

// MARK: - NSWindowGrabber (NSView subclass)

/// An `NSView` subclass that calls a closure with the hosting `NSWindow`
/// as soon as the view is inserted into the window hierarchy.
final class NSWindowGrabber: NSView {
    /// Called with the `NSWindow` reference when the view moves to a window,
    /// or `nil` when it is removed from one.
    var onWindow: (NSWindow?) -> Void

    /// Creates a grabber that invokes `onWindow` on every `viewDidMoveToWindow` call.
    init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    /// Not supported — `WindowGrabber` is created programmatically only.
    required init?(coder _: NSCoder) { fatalError("init(coder:) not supported") }

    /// Fires `onWindow` with the current `window` value whenever the view
    /// is added to or removed from a window hierarchy.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow(window)
    }
}

// MARK: - WindowGrabber (NSViewRepresentable)

/// A zero-size SwiftUI wrapper around `NSWindowGrabber`.
///
/// Attach via `.background(WindowGrabber { w in … })` to capture the
/// hosting `NSWindow` without affecting layout.
struct WindowGrabber: NSViewRepresentable {
    /// Called with the hosting `NSWindow` when the view enters the hierarchy.
    var onWindow: (NSWindow?) -> Void

    /// Creates the underlying `NSWindowGrabber` view.
    func makeNSView(context _: Context) -> NSWindowGrabber {
        NSWindowGrabber(onWindow: onWindow)
    }

    /// Propagates the latest closure so the grabber never holds a stale
    /// callback.
    func updateNSView(_ nsView: NSWindowGrabber, context _: Context) {
        nsView.onWindow = onWindow
    }
}
