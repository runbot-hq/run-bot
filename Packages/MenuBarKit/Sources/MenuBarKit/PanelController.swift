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
//     └── subview        NSHostingController  (adopter SwiftUI tree)
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
// SAFE ON NSGlassEffectView ANCESTORS (do not confuse with the above):
//   • cornerRadius on NSThemeFrame.layer   — sets visual rounding only;
//     does NOT force an offscreen compositing pass. Used in
//     clipWindowFrameBacking() to suppress square border pixel artefacts.
//   • cornerCurve = .continuous on NSThemeFrame.layer — same: purely
//     cosmetic, no compositing-pass consequence.
//   These two properties are safe to set on any ancestor. Only
//   masksToBounds forces the offscreen pass.
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
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, panel, hostingController, limits):
//   Assigned in setup(), not init(). Safe because setup() is called from
//   applicationDidFinishLaunching before any user interaction is possible.
//   isSetUp = true is set as the LAST statement in setup(), after all five
//   sub-calls complete, so every IUO is guaranteed assigned before any caller
//   can observe isSetUp == true.
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
    var hostingController: NSHostingController<MBKPanelContentView>!
    /// Live sizing limits handed to SwiftUI.
    var limits: MBKPanelLimits!

    /// Maximum content height in points, recomputed on every open and screen change.
    var maxContentHeight: CGFloat = 0

    // MARK: - Session state

    /// Guards against calling `setup()` more than once.
    /// `private(set)` — cross-file extensions read this flag (e.g. openPanel's
    /// precondition check) but must never write it; only `setup()` sets it to true.
    private(set) var isSetUp = false

    nonisolated(unsafe) var eventMonitor: Any?
    /// Workspace app-switch observer token. See `eventMonitor` for `nonisolated(unsafe)` rationale.
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?
    /// Screen-parameter observer token. See `eventMonitor` for `nonisolated(unsafe)` rationale.
    nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    /// Status-button centre X in screen coordinates from the most recent readable frame.
    var lastKnownAnchorX: CGFloat?

    /// The content size behind the frame currently on screen, for 1pt dedupe.
    /// Cleared on open and on close so a reopen always recomputes.
    var lastContentSize: CGSize?

    /// Prevents `onWillClose` from firing more than once per open/close cycle.
    var onWillCloseFired = false

    // MARK: - Private types

    private enum GlassConfig {
        static let subduedState: Int = 1
        static let variant: Int = 1
        static let scrimState: Int = 1
    }

    // MARK: - Init

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

    public func setup() {
        precondition(!isSetUp, "MBKPanelController.setup() called more than once.")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanelWindow()
        setupWorkspaceObserver()
        setupScreenObserver()
        isSetUp = true
        mbkLog("PanelController", "setup complete")
    }

    /// Builds the panel, the glass chrome, and the AL-pinned hosting view.
    ///
    /// AL PINS — four edges (leading, trailing, top, bottom):
    ///   The bottom pin is required so that every window resize driven by
    ///   `applyFrame` propagates a new concrete height proposal to SwiftUI.
    ///   Without it SwiftUI receives an unspecified proposal, fires
    ///   `onGeometryChange` once on the first layout pass, then goes silent —
    ///   window resizes never re-propose so content growth is never reported.
    ///
    ///   With the bottom pin: window resizes → bottom constraint changes →
    ///   SwiftUI receives a new concrete height → re-lays out → `onGeometryChange`
    ///   fires with the updated natural content size.
    ///
    /// sizingOptions = []:
    ///   Suppresses the intrinsicContentSize-driven sizing path entirely.
    ///   `onGeometryChange` on the inner VStack in `MBKPanelContentView` is
    ///   the sole measurement source. The intrinsicContentSize path is
    ///   incompatible with the bottom-pin architecture: if the hosting view
    ///   also advertises an intrinsic size, AppKit may use it to drive the
    ///   window size in addition to `applyFrame`, creating a feedback loop.
    ///
    /// WHY THIS DOES NOT CREATE A MEASUREMENT FEEDBACK LOOP:
    ///   `onGeometryChange` is on the *inner* VStack in `MBKPanelContentView`,
    ///   not the outer `.frame(.infinity)` fill. The inner VStack measures the
    ///   content's *natural* height before the outer fill expands to the window
    ///   bounds. So the sequence is:
    ///     applyFrame resizes window
    ///     → bottom pin proposes new height to SwiftUI
    ///     → inner VStack re-measures natural content height (unchanged if content hasn't grown)
    ///     → onGeometryChange fires only if natural height changed
    ///     → applyFrame only if content size changed (dedupe in applyMeasuredSize)
    ///   No loop. See PanelContent.swift for the inner/outer split.
    private func setupPanelWindow() {
        maxContentHeight = liveMaxContentHeight()
        limits = MBKPanelLimits(arrowCenterX: 0)

        let glassView = NSGlassEffectView(frame: .zero)
        glassView.style = .regular
        glassView.cornerRadius = metrics.cornerRadius
        glassView.autoresizingMask = [.width, .height]

        let kvcKeys = ["_subduedState", "_variant", "_scrimState"]
        let allKeysSupported = kvcKeys.allSatisfy {
            glassView.responds(to: NSSelectorFromString("set" + $0.prefix(1).uppercased() + $0.dropFirst() + ":"))
        }
        if allKeysSupported {
            glassView.setValue(GlassConfig.subduedState, forKey: "_subduedState")
            glassView.setValue(GlassConfig.variant, forKey: "_variant")
            glassView.setValue(GlassConfig.scrimState, forKey: "_scrimState")
        } else {
            mbkLog("PanelController", "⚠️ NSGlassEffectView KVC keys unavailable on"
                + " \(ProcessInfo.processInfo.operatingSystemVersionString)"
                + " — falling back to .regular style (lighter glass). File a radar.")
        }

        let hosting = NSHostingController(
            rootView: MBKPanelContentView(
                limits: limits,
                metrics: metrics,
                content: rootView,
                onSizeChange: { [weak self] size in
                    self?.applyMeasuredSize(size)
                }
            )
        )
        // sizingOptions = [] — suppress intrinsicContentSize-driven sizing.
        // onGeometryChange on the inner VStack is the sole measurement source.
        // The intrinsicContentSize path conflicts with the bottom-pin architecture.
        hosting.sizingOptions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = CGColor.clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController = hosting

        glassView.addSubview(hosting.view)
        // FOUR-EDGE pins — the bottom pin is load-bearing for the sizing pipeline.
        // See setupPanelWindow() header comment above for the full rationale.
        // ❌ DO NOT remove the bottom pin. Without it onGeometryChange fires once
        //    and goes silent — window resizes never re-propose to SwiftUI.
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: glassView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        let window = MBKPanel()
        window.contentView = glassView
        window.onCancel = { [weak self] in
            mbkLog("PanelController", "cancelOperation -- Escape, closing")
            self?.performClose()
        }
        panel = window

        clipWindowFrameBacking(window, cornerRadius: metrics.cornerRadius)
    }

    private func clipWindowFrameBacking(_ panel: MBKPanel, cornerRadius: CGFloat) {
        guard let frameView = panel.contentView?.superview else { return }
        #if DEBUG
        assert(
            NSStringFromClass(type(of: frameView)).contains("ThemeFrame"),
            "clipWindowFrameBacking: contentView.superview is \(NSStringFromClass(type(of: frameView))),"
            + " expected NSThemeFrame. Apple may have restructured the window hierarchy"
            + " — verify this function is still rounding the right view."
        )
        #endif
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
    }

    // MARK: - Root view replacement

    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        lastContentSize = nil
        hostingController.rootView = MBKPanelContentView(
            limits: limits,
            metrics: metrics,
            content: rootView,
            onSizeChange: { [weak self] size in
                self?.applyMeasuredSize(size)
            }
        )
        mbkLog("PanelController", "setRootView — rootView replaced, lastContentSize cleared")
    }

    public func invalidateContentSize() {
        guard isSetUp, let hostingController else { return }
        // Schedule a natural layout pass. onGeometryChange fires on the next
        // settled pass and calls applyMeasuredSize with the correct natural size.
        // ❌ DO NOT call layoutSubtreeIfNeeded() here — it forces a synchronous
        //    pass before SwiftUI settles, reads fittingSize at window height
        //    (not content height), and causes a visible snap.
        hostingController.view.invalidateIntrinsicContentSize()
        mbkLog("PanelController", "invalidateContentSize — scheduled natural layout pass")
    }

    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

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
