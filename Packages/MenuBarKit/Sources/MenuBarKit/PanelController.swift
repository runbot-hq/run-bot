// PanelController.swift
// MenuBarKit
//
// Owns the full NSPanel + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// WHY THIS IS NOT AN NSPopover ANYMORE:
//   NSPopover owns its arrow as AppKit chrome and bakes the arrow offset at
//   show() time. MenuBarKit resizes its content manually after show(), and no
//   amount of pre-seeding or re-anchoring made AppKit re-derive the arrow —
//   it stayed clipped (#2278, #2279, PR #2289). We now own one real borderless
//   panel and draw the bubble + arrow ourselves (MBKPanelMask), so the arrow is
//   recomputed with the frame and can never disagree with it.
//
//   ❌ NEVER reintroduce NSPopover.
//   ❌ NEVER add an invisible helper window to position this one. An earlier
//      attempt (PR #2292) used a ghost panel as a positioningView; it was
//      rejected. The panel below is the only window MenuBarKit creates.
//
// RESPONSIBILITIES:
//   - Create and show/hide the MBKPanel
//   - Manage the NSStatusItem button highlight
//   - Install/remove the outside-click NSEvent monitor
//   - Install/remove the NSWorkspace app-switch observer
//   - Recompute the height cap and the frame on screen-parameter changes
//   - Gate dismissal on the MBKOverlayGate
//   - Apply SwiftUI-reported content sizes through one frame pipeline
//
// STAY-OPEN-WHILE-SHEET-ACTIVE — deliberate trade-off (unchanged from before):
//   When a sheet (or file picker) is live, the panel stays open on app-switch
//   and outside-click. Every close path consults `overlayGate.hasActiveOverlay`.
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor } (not queue: .main):
//   queue: nil delivers on the poster's thread; Task { @MainActor } is the
//   Swift 6-correct hop to the main actor — compiler-enforced, not asserted.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, panel, effectView, hostingView,
// limits, coalescer):
//   Assigned in setup(), not init(). Safe because setup() is called from
//   applicationDidFinishLaunching before any user interaction is possible.
//
// nonisolated(unsafe) — the three observer tokens:
//   All hold opaque tokens from AppKit APIs that are not Sendable. Every live
//   read/write is @MainActor-isolated. Safe under the singleton lifetime
//   assumption — see the deinit note below.
//
// CROSS-FILE EXTENSION ACCESS (PanelController+*.swift):
//   Members accessed by extensions in other files are `internal` (the Swift
//   default). `fileprivate` would not reach across files.
//
// FILE ORGANISATION:
//   PanelController.swift            — stored properties, init, setup, deinit
//   PanelController+Frame.swift      — anchor reading and the frame pipeline
//   PanelController+Open.swift       — toggle/open/close, highlight
//   PanelController+Observers.swift  — workspace, screen, mouse and key monitors

import AppKit
import SwiftUI

/// Manages the full anchored-panel and `NSStatusItem` lifecycle for a macOS menu-bar app.
///
/// Inject a root SwiftUI view and an `MBKOverlayGate` at init time, then call `setup()`
/// from `applicationDidFinishLaunching`. All app-specific behaviour is provided via
/// the `onWillShow`, `onDidShow`, and `onWillClose` closures.
@MainActor
public final class MBKPanelController: NSObject, MBKPanelControllerProtocol {

    // MARK: - Configuration

    /// Overlay gate — consulted by every close path, reset on close.
    /// `internal` (default) so extension files can access it.
    let overlayGate: MBKOverlayGate
    /// SF Symbol name for the status-bar icon.
    private let symbolName: String
    /// Minimum allowed content width.
    let minWidth: CGFloat
    /// Maximum allowed content width.
    let maxWidth: CGFloat
    /// Fraction of the screen's visible height the content may occupy.
    ///
    /// Evaluated live on every open and on every screen-parameter change — never
    /// snapshotted at launch. The launch-time snapshot was the stale-cap bug in #2279.
    let maxHeightFraction: CGFloat
    /// Chrome metrics for the bubble we draw.
    let metrics: MBKPanelMetrics
    /// The current root SwiftUI view, wrapped in `AnyView`.
    var rootView: AnyView

    /// Called just before the panel is shown. Use this to refresh content.
    public var onWillShow: (() -> Void)?
    /// Called one actor-turn after the panel is shown.
    public var onDidShow: (() -> Void)?
    /// Called when the panel is about to close.
    /// `wasForced` is `true` when closed because an outside click arrived while a sheet was live.
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    // MARK: - Assigned in setup()

    /// The status-bar item that owns the trigger button.
    var statusItem: NSStatusItem!
    /// The one window MenuBarKit owns.
    var panel: MBKPanel!
    /// The panel's content view; carries the bubble mask and the material.
    var effectView: NSVisualEffectView!
    /// Hosts the root SwiftUI view.
    var hostingView: MBKHostingView!
    /// Live sizing limits handed to SwiftUI.
    var limits: MBKPanelLimits!
    /// Coalesces size invalidations into one frame apply per runloop turn.
    var coalescer: MBKSizeCoalescer!

    // MARK: - Session state

    /// Guards against calling `setup()` more than once.
    private var isSetUp = false
    /// Global mouse-down event monitor token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var eventMonitor: Any?
    /// Workspace app-switch observer token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?
    /// Screen-parameter observer token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    /// Status-button centre X in screen coordinates from the most recent readable frame.
    ///
    /// The button window reports a usable frame even while the auto-hide menu bar is
    /// hidden, so this is normally fresh; it exists only as a fallback for the case
    /// where the button has no window at all.
    var lastKnownAnchorX: CGFloat?

    /// The content size behind the frame currently on screen, for 1pt dedupe.
    /// Cleared on open and on close so a reopen always recomputes.
    var lastContentSize: CGSize?

    /// Prevents `onWillClose` from firing more than once per open/close cycle.
    var onWillCloseFired = false

    // MARK: - Init

    /// Creates the controller with a root SwiftUI view and shared overlay gate.
    /// - Parameters:
    ///   - rootView: The root view displayed inside the panel.
    ///   - overlayGate: Shared gate; blocks dismiss while a sheet or picker is live.
    ///   - symbolName: SF Symbol name for the status-bar icon. Defaults to `"menubar.rectangle"`.
    ///   - minWidth: Minimum content width (default 200).
    ///   - maxWidth: Maximum content width (default 600).
    ///   - maxHeightFraction: Fraction of the screen's visible height the content
    ///     may occupy (default 0.8). Applied live, never snapshotted.
    ///   - metrics: Bubble chrome metrics. Defaults to `MBKPanelMetrics.default`.
    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeightFraction: CGFloat = 0.8,
        metrics: MBKPanelMetrics = .default
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeightFraction = maxHeightFraction
        self.metrics = metrics
        self.rootView = AnyView(rootView)
    }

    // MARK: - Setup

    /// Wires the status item, panel, and observers.
    ///
    /// **Must be called from `applicationDidFinishLaunching`** before any user
    /// interaction is possible.
    ///
    /// ❌ NEVER call `setup()` more than once. A `precondition` guards this at runtime.
    public func setup() {
        precondition(!isSetUp, "MBKPanelController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanelWindow()
        setupWorkspaceObserver()
        setupScreenObserver()
        mbkLog("PanelController", "setup complete")
    }

    /// Builds the panel, its visual-effect content view, and the hosting view.
    private func setupPanelWindow() {
        limits = MBKPanelLimits(
            minWidth: minWidth,
            maxWidth: maxWidth,
            maxContentHeight: liveMaxContentHeight()
        )

        // The coalescer must exist before the hosting view can report a size.
        coalescer = MBKSizeCoalescer { [weak self] in
            self?.applyMeasuredSize()
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effectView = effect

        let hosting = MBKHostingView(
            rootView: MBKPanelContentView(limits: limits, content: rootView)
        )
        hosting.autoresizingMask = []
        hosting.onIntrinsicSizeChange = { [weak self] in
            self?.coalescer.schedule()
        }
        hostingView = hosting
        effect.addSubview(hosting)

        let window = MBKPanel()
        window.contentView = effect
        window.onCancel = { [weak self] in
            mbkLog("PanelController", "cancelOperation -- Escape, closing")
            self?.performClose()
        }
        panel = window
    }

    // MARK: - Root view replacement

    /// Replaces the panel's root view at runtime.
    /// Safe to call before or after `setup()`.
    /// - Parameter view: The new root view.
    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingView.rootView = MBKPanelContentView(limits: limits, content: rootView)
        mbkLog("PanelController", "setRootView — rootView replaced")
    }

    // MARK: - Status item

    /// Replaces the status-bar button image.
    /// - Parameter image: The new template image.
    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    /// Creates and configures the `NSStatusItem` and its button.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: - Deallocation

    /// Removes the observers and monitors. `NSEvent.removeMonitor` is thread-safe, and
    /// the controller outlives all concurrent work under normal singleton usage.
    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
