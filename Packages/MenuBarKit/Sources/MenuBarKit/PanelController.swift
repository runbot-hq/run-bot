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
//   contentView = NSGlassEffectView   (direct — no wrapper)
//     └── contentView    MBKHostingView  (adopter SwiftUI tree)
//
//   NSGlassEffectView MUST be the direct panel.contentView. Any intervening
//   layer-backed ancestor (plain NSView, NSVisualEffectView) routes glass through
//   an offscreen compositing pass. addChildWindow() (sheet open) resets that pass
//   → corners revert to rect for the lifetime of the sheet.
//   Per NSGlassEffectView.h only .contentView is clipped by cornerRadius;
//   the glass cannot sample other glass so SwiftUI .glassEffect in the hosted
//   tree still works correctly.
//   ❌ NEVER put an NSVisualEffectView back in this window (pre-26 vibrancy).
//   ❌ NEVER wrap NSGlassEffectView in any intermediate NSView.
//   ❌ NEVER wrap the hosted tree in `.glassEffect(...)`.
//
//   ❌ NEVER reintroduce NSPopover.
//   ❌ NEVER add an invisible helper window to position this one. An earlier
//      attempt (PR #2292) used a ghost panel as a positioningView; it was
//      rejected. The panel below is the only window MenuBarKit creates.
//
// WHAT BREAKS CORNERS (do not re-introduce):
//   • masksToBounds = true on any ancestor of NSGlassEffectView
//     Forces an offscreen compositing pass → glass severs live backdrop.
//   • NSVisualEffectView wrapper as panel.contentView
//     Adding a VEV ancestor caused glass-goes-square-on-sheet regression.
//   • CAShapeLayer mask on any layer
//   • Any async re-assertion of cornerRadius after addChildWindow()
//
// ROUNDED CORNERS — HISTORY (approaches tried and rejected):
//   All of these regress to rect corners on sheet open (addChildWindow):
//   1. NSVisualEffectView.cornerRadius / masksToBounds  → reset by addChildWindow()
//   2. CAShapeLayer mask                                → clips pixels, not blur compositor
//   3. NSGlassEffectView.cornerRadius (with VEV ancestor as contentView)
//                                                        → reset by addChildWindow()
//   4. NSGlassEffectView.clipsToBounds (same VEV-ancestor setup)
//                                                        → reset by addChildWindow()
//   5. NSPanel subclass overriding addChildWindow()     → AppKit resets again async after super
//   6. DispatchQueue.main.async re-assertion            → still a race, still regresses
//   7. plain NSView wrapper + masksToBounds = true      → WORKS for corners BUT forces offscreen
//                                                          compositing pass → glass goes flat
//                                                          dark rectangle when sheet opens
//   8–11. Various NSVisualEffectView clipView material/blending/maskImage approaches
//         → all removed; clipView no longer exists in the codebase.
//
//   CURRENT (working): NSGlassEffectView as direct panel.contentView.
//   glassView.cornerRadius clips natively inside glass compositor — no offscreen pass,
//   survives addChildWindow. clipWindowFrameBacking() rounds the AppKit frame-backing
//   layer (contentView.superview) to suppress residual square border pixels.
//
// HOSTING CONTROLLER VIEW TRANSPARENCY:
//   NSHostingController creates its NSView with an opaque CALayer background.
//   SwiftUI's .background(.clear) does NOT reach this layer.
//   wantsLayer = true forces immediate layer creation, so layer is non-nil before
//   the view is attached to any superview. layer?.backgroundColor can therefore be
//   zeroed immediately after wantsLayer = true — ordering relative to contentView
//   assignment does not matter. (An earlier version of this header incorrectly stated
//   that zeroing before attachment was a silent no-op — that was wrong.)
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
    /// Live sizing limits handed to SwiftUI.
    var limits: MBKPanelLimits!
    /// Coalesces size invalidations into one frame apply per runloop turn.
    var coalescer: MBKSizeCoalescer!

    // MARK: - Session state

    /// Guards against calling `setup()` more than once.
    var isSetUp = false
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

        // NSGlassEffectView as DIRECT panel.contentView.
        // CRITICAL: any intervening layer-backed ancestor (NSView wrapper, NSVisualEffectView,
        // wantsLayer=true view) routes glass through an offscreen compositing pass.
        // addChildWindow() (fired on sheet open) resets that pass → corners revert to rect
        // for the lifetime of the sheet. Direct contentView is the only position that
        // survives addChildWindow() without regression.
        // ❌ NEVER re-introduce MBKPanelChromeView or any wrapper here.
        let glassView = NSGlassEffectView(frame: .zero)
        glassView.style = .regular          // required base — KVC keys below have no effect without it
        glassView.cornerRadius = metrics.cornerRadius
        glassView.autoresizingMask = [.width, .height]
        // Private KVC dark-glass tuning. All three must be set together after .style = .regular.
        // Value 1 = darker/richer glass. Do NOT revert to 0 — empirically lighter on macOS 26.
        // Undocumented; may change in a future OS release.
        //
        // Each key controls a distinct stage of the same compositor pipeline:
        //   _subduedState = 1  Locks the glass to its own dark intrinsic tone instead of
        //                      sampling desktop colours. ("Subdued" in Apple's naming means
        //                      muted-toward-desktop; = 1 disables that sampling.)
        //   _variant      = 1  Selects the dark-glass rendering variant of the compositor.
        //   _scrimState   = 1  Enables the scrim layer that reinforces the dark tone.
        //
        // All three must be set together — partial combinations produce light or inconsistent
        // glass. These KVC values only affect tint/intensity, not the compositing path, so
        // they do NOT interact with the masksToBounds / offscreen-pass issue.
        // setValue(_:forKey:) does not throw — a missing key raises NSUndefinedKeyException at
        // runtime (uncatchable from Swift). If Apple removes a key in a future OS, the app will
        // crash on first open with: [NSGlassEffectView setValue:forUndefinedKey:]. To diagnose:
        // look for that message in the crash log.
        //
        // NOTE on the selector check below: responds(to:) checks for the ObjC setter selector
        // (e.g. set_SubduedState:), which is NOT the same guarantee as KVC compliance.
        // An object can respond to the setter selector but still raise NSUndefinedKeyException
        // on setValue(_:forKey:) if the key is not registered in the KVO/KVC system.
        // The inverse is also possible. This check guards against the most common removal
        // scenario (Apple deletes the property entirely), but cannot guarantee safety against
        // a key that loses KVC compliance while retaining its setter. A fully robust guard
        // would use value(forKey:) in a try/catch via ObjC bridging.
        // TODO: revisit at macOS 26.x betas — undocumented KVC may change without notice.
        // If this fallback fires, file a radar and restore .regular style gracefully.
        let kvcKeys = ["_subduedState", "_variant", "_scrimState"]
        let allKeysSupported = kvcKeys.allSatisfy {
            glassView.responds(to: NSSelectorFromString("set" + $0.prefix(1).uppercased() + $0.dropFirst() + ":"))
        }
        if allKeysSupported {
            glassView.setValue(1, forKey: "_subduedState")
            glassView.setValue(1, forKey: "_variant")
            glassView.setValue(1, forKey: "_scrimState")
        } else {
            mbkLog("PanelController", "⚠️ NSGlassEffectView KVC keys unavailable on \(ProcessInfo.processInfo.operatingSystemVersionString) — falling back to .regular style (lighter glass). File a radar.")
        }

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
        // Hosting view must be transparent — NSHostingView has an opaque CALayer by default.
        // SwiftUI .background(.clear) does not reach this layer. wantsLayer = true forces
        // immediate layer creation so backgroundColor can be zeroed before attachment.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // CRITICAL: hosting is added via addSubview, NOT glassView.contentView.
        // glassView.contentView puts the SwiftUI tree inside the glass compositor —
        // glass-inside-glass flattens every GlassEffectContainer in the adopter's content.
        // addSubview keeps the hosting view as a plain sibling layer above glassView,
        // outside the compositor, so GlassEffectContainer and .glassEffect elements work.
        // cornerRadius clipping is handled by MBKBubbleShape clipShape on the SwiftUI side.
        glassView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glassView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        let window = MBKPanel()
        window.contentView = glassView   // glass IS the contentView — no wrapper
        window.onCancel = { [weak self] in
            mbkLog("PanelController", "cancelOperation -- Escape, closing")
            self?.performClose()
        }
        panel = window

        // Suppress faint square border pixel artefacts on NSThemeFrame.
        // NO masksToBounds — would route glass through offscreen compositing pass.
        clipWindowFrameBacking(window, cornerRadius: metrics.cornerRadius)
    }

    /// Rounds the NSThemeFrame layer (AppKit's private window-chrome view, contentView.superview)
    /// to suppress faint square border pixel artefacts visible on borderless panels with
    /// `backgroundColor = .clear`.
    ///
    /// `panel.contentView?.superview` is `NSThemeFrame` — AppKit's private window-chrome view
    /// that wraps the entire window. It exists on borderless panels and composites a faint
    /// rectangular frame at window edges, visible as square pixel artefacts when
    /// `backgroundColor = .clear`. We round its layer without `masksToBounds`.
    ///
    /// ❌ DO NOT set `masksToBounds = true` — `NSThemeFrame` is an ancestor of `NSGlassEffectView`.
    /// `masksToBounds` forces the entire window into an offscreen compositing pass, severing
    /// the live backdrop connection and flattening the glass to a dark rectangle.
    /// `cornerRadius` alone is sufficient to suppress the faint square border pixel artefacts.
    private func clipWindowFrameBacking(_ panel: MBKPanel, cornerRadius: CGFloat) {
        guard let frameView = panel.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
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

// MARK: - NSView helpers

/// Helpers used internally by `PanelController` to manage subview layout and scroll behaviour.
extension NSView {
    /// Walks the entire subview tree and collects every NSScrollView descendant.
    /// Used to nuke drawsBackground on open so no scroll view paints over the glass bubble.
    fileprivate func descendantScrollViews() -> [NSScrollView] {
        var result: [NSScrollView] = []
        for sub in subviews {
            if let sv = sub as? NSScrollView { result.append(sv) }
            result.append(contentsOf: sub.descendantScrollViews())
        }
        return result
    }
}
