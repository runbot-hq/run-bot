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
//   panel and draw the bubble ourselves, so the frame is recomputed
//   with the content and can never disagree with it.
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
//   assignment does not matter.
//
// SIZING PIPELINE — read before touching setupPanelWindow():
//   Goal: list height drives panel height dynamically as items expand/collapse.
//
//   Signal: KVO on hostingController.preferredContentSize.
//   NSHostingController writes preferredContentSize after every layout pass
//   that produces a new ideal size under an unspecified proposal — but only
//   when sizingOptions = .preferredContentSize is set. Without it, AppKit
//   never populates the property and KVO never fires.
//
//   WHY NOT onGeometryChange (historical):
//   When rootView was wrapped in AnyView, SwiftUI could not compute ideal
//   height through the type erasure barrier. Now that rootView is a concrete
//   type (RootEnvView), .preferredContentSize works correctly. The bottom-pin
//   constraint provides the measured height back to SwiftUI for re-proposal.
//
//   ✅ Four-edge AL pins (leading + trailing + top + bottom)  — all required.
//   After applyMeasuredSize resizes the window, the bottom pin re-proposes
//   the new concrete height to SwiftUI. SwiftUI re-measures; if content height
//   changed preferredContentSize changes and KVO fires. Without the bottom pin
//   KVO goes silent after the first measurement.
//
//   limits.maxContentHeight is @Observable — updated on every open and every
//   screen-parameter change so the SwiftUI cap is always current.
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
// WORKSPACE OBSERVER — why closures live in MBKPanelObservers (not here):
//   Task { @MainActor [weak self] } in a generic class captures self as
//   MBKPanelController<Content>, causing a spurious [#SendableMetatypes]
//   warning for Content.Type even when Content is never used in the body.
//   Moving the closures into the non-generic MBKPanelObservers eliminates
//   the generic metatype from every capture list. See PanelObservers.swift.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, panel, hostingController, limits):
//   Assigned in setup(), not init(). Safe because setup() is called from
//   applicationDidFinishLaunching before any user interaction is possible.
//   isSetUp = true is set as the LAST statement in setup(), after all four
//   sub-calls complete, so every IUO is guaranteed assigned before any caller
//   can observe isSetUp == true.
//
//   isSetUp guards the precondition in openPanel() — no caller can reach
//   openPanel() before setup() finishes.
//   hasOpenedOnce guards applyFrame and applyMeasuredSize against pre-open
//   KVO or invalidation calls that arrive before the first openPanel().
//   The two guards are complementary, not redundant: isSetUp catches
//   programming errors (openPanel before setup), while hasOpenedOnce
//   catches the normal KVO timing window where the measurement system
//   fires before the first user interaction.
//
// nonisolated(unsafe) — the observer tokens:
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

private enum GlassConfig {
    static let subduedState: Int = 1
    static let variant: Int = 1
    static let scrimState: Int = 1
}

/// Manages the full anchored-panel and `NSStatusItem` lifecycle for a macOS menu-bar app.
@MainActor
public final class MBKPanelController<Content: View>: NSObject, MBKPanelControllerProtocol {

    // MARK: - Configuration

    let overlayGate: MBKOverlayGate
    private let symbolName: String
    let maxHeightFraction: CGFloat
    let metrics: MBKPanelMetrics
    var rootView: Content

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    // MARK: - Assigned in setup()

    var statusItem: NSStatusItem!
    var panel: MBKPanel!
    var hostingController: NSHostingController<MBKPanelContentView<Content>>!
    var limits: MBKPanelLimits!
    nonisolated(unsafe) var preferredContentSizeObservation: NSKeyValueObservation?

    // MARK: - Session state

    private(set) var isSetUp = false
    nonisolated(unsafe) var observers: MBKPanelObservers?
    var lastKnownAnchorX: CGFloat?
    var lastContentSize: CGSize?
    var onWillCloseFired = false
    var hasOpenedOnce = false

    // MARK: - Init

    @objc func togglePanel() {
        togglePanelInternal()
    }

    public init(
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
        self.rootView = rootView
    }

    // MARK: - Setup

    public func setup() {
        precondition(!isSetUp, "MBKPanelController.setup() called more than once.")
        observers = MBKPanelObservers(controller: self)
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanelWindow()
        setupWorkspaceObserver()
        setupScreenObserver()
        isSetUp = true
        mbkLog("PanelController", "setup complete")
    }

    private func setupPanelWindow() {
        limits = MBKPanelLimits(maxContentHeight: liveMaxContentHeight())
        mbkLog("PanelController", "setupPanelWindow -- limits created maxContentHeight=\(limits.maxContentHeight)")

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
                + " — falling back to .regular style. File a radar.")
        }

        let hc = NSHostingController(
            rootView: MBKPanelContentView(limits: limits, metrics: metrics, content: rootView)
        )
        hc.sizingOptions = .preferredContentSize
        mbkLog("PanelController", "setupPanelWindow -- sizingOptions=\(hc.sizingOptions.rawValue) rootView=\(type(of: hc.rootView))")
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
        mbkLog("PanelController", "setupPanelWindow -- four-edge AL pins activated")

        let vcForKVO: NSViewController = hc
        preferredContentSizeObservation = vcForKVO.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak observers] _, change in
            guard let newSize = change.newValue else { return }
            Task { @MainActor [weak observers] in
                observers?.handlePreferredContentSizeChange(newSize)
            }
        }
        mbkLog("PanelController", "setupPanelWindow -- KVO on preferredContentSize registered")

        let window = MBKPanel()
        window.contentView = glassView
        window.onCancel = { [weak self] in
            mbkLog("PanelController", "cancelOperation -- Escape, closing")
            self?.performClose()
        }
        panel = window
        mbkLog("PanelController", "setupPanelWindow -- MBKPanel created")

        clipWindowFrameBacking(window, cornerRadius: metrics.cornerRadius)
    }

    private func clipWindowFrameBacking(_ panel: MBKPanel, cornerRadius: CGFloat) {
        guard let frameView = panel.contentView?.superview else { return }
        if !NSStringFromClass(type(of: frameView)).contains("ThemeFrame") {
            mbkLog("PanelController",
                "⚠️ clipWindowFrameBacking: contentView.superview is \(NSStringFromClass(type(of: frameView))),"
                + " expected NSThemeFrame — corner rounding may not apply correctly."
            )
        }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor
        frameView.layer?.cornerRadius = cornerRadius
        frameView.layer?.cornerCurve = .continuous
    }

    public func invalidateContentSize() {
        hostingController.view.invalidateIntrinsicContentSize()
    }

    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    public func routeDidChange() {
        lastContentSize = nil
        mbkLog("PanelController", "routeDidChange -- cache cleared")
        guard isShown else { return }
        if let anchor = readAnchor() {
            mbkLog("PanelController", "routeDidChange -- anchor anchorX=\(anchor.anchorX) buttonScreen=\(statusItem?.button?.window?.screen != nil)")
        } else {
            mbkLog("PanelController", "routeDidChange -- anchor NIL")
        }
        Task { @MainActor [weak self] in
            guard let self, isShown else { return }
            let pcs = hostingController.preferredContentSize
            guard pcs.width > 0, pcs.height > 0 else { return }
            mbkLog("PanelController", "routeDidChange deferred -- preferredContentSize=\(pcs) buttonScreen=\(statusItem?.button?.window?.screen != nil)")
            applyMeasuredSize(pcs)
        }
    }

    /// Creates the NSStatusItem, injects `MBKStatusBarButton` + `MBKStatusBarButtonCell`,
    /// and wires the toggle action.
    ///
    /// Two `object_setClass` swaps are required — one on the button, one on its cell:
    /// - `MBKStatusBarButton.highlight(_:)` guards the public `NSButton` path.
    /// - `MBKStatusBarButtonCell.highlight(_:withFrame:inView:)` guards the internal
    ///   cell path AppKit calls directly during mouse tracking and key-window transitions,
    ///   bypassing the button-level override entirely. Confirmed necessary by diagnostic
    ///   logs showing the button override firing correctly while highlight still cleared.
    ///   See #2440.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Inject button subclass.
            let beforeBtn = NSStringFromClass(type(of: button as AnyObject))
            object_setClass(button, MBKStatusBarButton.self)
            let afterBtn = NSStringFromClass(type(of: button as AnyObject))
            mbkLog("PanelController", "setupStatusItem -- button class: \(beforeBtn) → \(afterBtn) castOK=\((button as? MBKStatusBarButton) != nil)")

            // Inject cell subclass and wire back-reference.
            // Must run AFTER the button swap so the button is already MBKStatusBarButton
            // when injectCellSubclass() sets cell.button = self.
            if let mbkButton = button as? MBKStatusBarButton {
                let beforeCell = NSStringFromClass(type(of: button.cell as AnyObject))
                mbkButton.injectCellSubclass()
                let afterCell = NSStringFromClass(type(of: button.cell as AnyObject))
                mbkLog("PanelController", "setupStatusItem -- cell class: \(beforeCell) → \(afterCell) cellCastOK=\((button.cell as? MBKStatusBarButtonCell) != nil)")
            }

            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.sendAction(on: .leftMouseDown) // keep — still needed for mouseDown dispatch
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: - Deallocation

    deinit {
        preferredContentSizeObservation?.invalidate()
        preferredContentSizeObservation = nil
    }
}
