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
//   panel and draw the bubble + arrow ourselves, so the arrow is recomputed
//   with the frame and can never disagree with it.
//
// HOW THE WINDOW IS LAYERED (back to front) — and why:
//   contentView (plain NSView)
//     ├── MBKPanelChromeView   Liquid Glass bubble + arrow, AppKit, pinned
//     └── MBKHostingView       the adopter's SwiftUI content, pinned, on top
//   The chrome is AppKit and not SwiftUI because glass cannot sample other
//   glass: a `.glassEffect` ancestor around the hosted tree flattens every
//   `GlassEffectContainer` the adopter draws (that was the device regression
//   after 825e3cf). NSPopover's chrome always lived at the window layer, which
//   is exactly what MBKPanelChromeView reproduces. It is also what gives the
//   window real backing alpha, without which macOS hit-tests the near-zero
//   pixels of a clear window and delivers clicks to the app behind the panel.
//   See PanelChrome.swift for the full rationale.
//   ❌ NEVER put an NSVisualEffectView back in this window (pre-26 vibrancy).
//   ❌ NEVER wrap the hosted tree in `.glassEffect(...)`.
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
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, panel, hostingView, limits,
// coalescer):
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

    // MARK: - Constants

    /// Content size used for the first frame when SwiftUI has not measured yet.
    ///
    /// Purely cosmetic: it only decides where the panel is drawn for the single
    /// frame before the real measurement lands. Seeing `FALLBACK` in the log
    /// during normal use means the measurement pipeline is broken.
    static let fallbackContentSize = CGSize(width: 320, height: 240)

    // MARK: - Configuration

    /// Overlay gate — consulted by every close path, reset on close.
    /// `internal` (default) so extension files can access it.
    let overlayGate: MBKOverlayGate
    /// SF Symbol name for the status-bar icon.
    private let symbolName: String
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
    /// Hosts the root SwiftUI view.
    var hostingView: MBKHostingView!
    /// Draws the Liquid Glass bubble and arrow below the hosting view.
    var chromeView: MBKPanelChromeView!
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

    /// The raw hosting-view measurement behind `lastContentSize`.
    ///
    /// Only used by the layout-pass safety net so it can tell "SwiftUI laid out
    /// again at the same size" (do nothing) from "the content actually grew"
    /// (schedule an apply). Cleared alongside `lastContentSize`.
    var lastMeasuredSize: CGSize?

    /// `true` while `applyFrame(content:reason:)` is driving a layout pass.
    ///
    /// `panel.setFrame` and the explicit `layoutSubtreeIfNeeded()` inside
    /// `applyFrame` both make the hosting view lay out, which re-enters the
    /// layout-pass hook. This flag makes that re-entry a no-op; `applyFrame`
    /// re-checks the measurement itself once the flag is clear.
    var isApplyingFrame = false

    /// Prevents `onWillClose` from firing more than once per open/close cycle.
    var onWillCloseFired = false

    /// `true` once `openPanel()` has run for the first time.
    ///
    /// Before that the status item has no on-screen position yet, so the anchor
    /// reads as `topY=0` and the pipeline would write a nonsense frame for every
    /// launch-time layout pass. See `frameWritesAllowed()`.
    var hasOpenedOnce = false

    /// Ensures the pre-open skip is logged at most once per process.
    var didLogPreOpenSkip = false

    // MARK: - Init

    /// Creates the controller with a root SwiftUI view and shared overlay gate.
    /// - Parameters:
    ///   - rootView: The root view displayed inside the panel.
    ///   - overlayGate: Shared gate; blocks dismiss while a sheet or picker is live.
    ///   - symbolName: SF Symbol name for the status-bar icon. Defaults to `"menubar.rectangle"`.
    ///   - maxHeightFraction: Fraction of the screen's visible height the content
    ///     may occupy (default 0.8). Applied live, never snapshotted.
    ///   - metrics: Bubble chrome metrics. Defaults to `MBKPanelMetrics.default`.
    ///
    /// - Note: There is deliberately no width parameter. Width is the adopter's
    ///   business: a global min/max width in MenuBarKit applies to *every* route
    ///   the adopter shows, which stretches fixed-width screens to the widest
    ///   route's minimum. Put `.frame(minWidth:maxWidth:)` on the views that want
    ///   it. MenuBarKit only refuses to grow wider than the screen.
    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        maxHeightFraction: CGFloat = 0.8,
        metrics: MBKPanelMetrics = .default
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
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

    /// Builds the panel, its clear content view, the glass chrome, and the pinned hosting view.
    ///
    /// AUTO LAYOUT IS LOAD-BEARING HERE — do not "simplify" it back to
    /// autoresizing masks. `NSHostingView` only creates and maintains its
    /// intrinsic-content-size constraints while Auto Layout is in use in the
    /// containing window (AppKit header, `sizingOptions`). Without the four pins
    /// below, `invalidateIntrinsicContentSize()` fires once and never again, and
    /// the window stays frozen at its first measured size while the content
    /// silently overflows it.
    ///
    /// The chrome is added *first* so it stays behind the hosting view; both are
    /// pinned to the same four edges, so the bubble is always exactly the window.
    private func setupPanelWindow() {
        limits = MBKPanelLimits(maxContentHeight: liveMaxContentHeight(), arrowCenterX: 0)

        // The coalescer must exist before the hosting view can report a size.
        coalescer = MBKSizeCoalescer { [weak self] in
            self?.applyMeasuredSize()
        }

        // Plain, fully transparent container. The chrome below draws the bubble.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]

        let chrome = MBKPanelChromeView(metrics: metrics)
        chromeView = chrome
        container.addSubview(chrome)

        let hosting = MBKHostingView(
            rootView: MBKPanelContentView(limits: limits, metrics: metrics, content: rootView)
        )
        hosting.onIntrinsicSizeChange = { [weak self] in
            self?.coalescer?.schedule()
        }
        hosting.onLayoutPass = { [weak self] in
            self?.scheduleIfMeasurementChanged(reason: "layout")
        }
        hostingView = hosting
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let window = MBKPanel()
        window.contentView = container
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
        hostingView.rootView = MBKPanelContentView(limits: limits, metrics: metrics, content: rootView)
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
