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
//     └── view    NSHostingController.view  (adopter SwiftUI tree)
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
//   isSetUp = true is set as the LAST statement in setup(), after all four
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
    /// Hosts the root SwiftUI view. `sizingOptions = []` so AppKit measures under
    /// an unspecified proposal and writes the result to `preferredContentSize`.
    var hostingController: NSHostingController<MBKPanelContentView>!
    /// Live sizing limits handed to SwiftUI.
    var limits: MBKPanelLimits!
    /// KVO token for `hostingController.preferredContentSize`.
    nonisolated(unsafe) var sizeObservation: NSKeyValueObservation?

    // MARK: - Session state

    /// Guards against calling `setup()` more than once.
    private(set) var isSetUp = false

    nonisolated(unsafe) var eventMonitor: Any?
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?
    nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    var lastKnownAnchorX: CGFloat?
    var lastContentSize: CGSize?
    var lastMeasuredSize: CGSize?
    var isApplyingFrame = false
    var onWillCloseFired = false
    var hasOpenedOnce = false
    var didLogPreOpenSkip = false

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

    private func setupPanelWindow() {
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

        let hc = NSHostingController(
            rootView: MBKPanelContentView(limits: limits, metrics: metrics, content: rootView)
        )
        hc.sizingOptions = []
        let hv = hc.view
        hv.translatesAutoresizingMaskIntoConstraints = false
        hv.wantsLayer = true
        hv.layer?.backgroundColor = CGColor.clear
        hostingController = hc

        glassView.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hv.topAnchor.constraint(equalTo: glassView.topAnchor),
            hv.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        sizeObservation = hc.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let newSize = change.newValue, newSize.width > 0, newSize.height > 0 else { return }
            Task { @MainActor [weak self] in
                self?.applyMeasuredSize(newSize)
            }
        }

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
            + " expected NSThemeFrame."
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
        lastMeasuredSize = nil
        hostingController.rootView = MBKPanelContentView(limits: limits, metrics: metrics, content: rootView)
        mbkLog("PanelController", "setRootView — rootView replaced, lastContentSize cleared")
    }

    public func invalidateContentSize() {
        // NSHostingController re-measures automatically via preferredContentSize KVO;
        // nothing to poke manually.
        mbkLog("PanelController", "invalidateContentSize — no-op under preferredContentSize pipeline")
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
        sizeObservation?.invalidate()
        sizeObservation = nil
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
