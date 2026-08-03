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

// Plain import — @preconcurrency is not needed here since the KVO fix (upcasting
// to NSViewController + capturing [weak observers]) removed the last Task site that
// triggered [#SendableMetatypes]. Using @preconcurrency would blanket-suppress all
// AppKit Sendable diagnostics in this file, hiding future regressions.
import AppKit
import SwiftUI
// NSGlassEffectView private KVC keys — all three set to 1 to produce dark glass.
//
// Each key controls a distinct stage of the same compositor pipeline:
// - `_subduedState = 1`  Locks the glass to its own dark intrinsic tone instead of
//                        sampling desktop colours.
// - `_variant      = 1`  Selects the dark-glass rendering variant of the compositor.
// - `_scrimState   = 1`  Enables the scrim layer that reinforces the dark tone.
//
// All three must be set together. Setting fewer than all three leaves the pipeline
// misaligned — partial combinations produce light or inconsistent glass.
//
// Counter-intuitive: value `1` produces darker/richer glass than `0` in this panel
// context. Do NOT revert to `0` — empirically verified lighter on macOS 26.
// These keys are undocumented and may change in a future OS update.
// Private SPI values for `NSGlassEffectView` KVC keys.
//
// These values are applied via `setValue(_:forKey:)` in `setupPanelWindow()`.
// The exact semantics are unknown — they are private SPI keys on NSGlassEffectView
// and may change in future OS releases. If the glass appearance regresses,
// check these values first.
/// Groups the three NSGlassEffectView KVC constants that configure the panel's
/// Liquid Glass appearance. Kept as a named enum (rather than inlined at the
/// call site) so that all three values are documented and discoverable in one
/// place, an OS-update audit has a single location to check, and the names
/// make the KVC semantics legible without requiring a comment on every
/// `setValue(_:forKey:)` line.
/// - Note: Do NOT inline these values or dissolve this enum — the namespace
///   is intentional.
private enum GlassConfig {
    /// Subdued/inactive appearance (matches system panels).
    static let subduedState: Int = 1
    /// Default panel variant.
    static let variant: Int = 1
    /// Enables the scrim layer that reinforces the dark tone.
    static let scrimState: Int = 1
}

/// Manages the full anchored-panel and `NSStatusItem` lifecycle for a macOS menu-bar app.
@MainActor
public final class MBKPanelController<Content: View>: NSObject, MBKPanelControllerProtocol {

    // MARK: - Configuration

    /// Overlay gate tracking sheet and file-picker state.
    let overlayGate: MBKOverlayGate
    /// System symbol name for the status item button image.
    private let symbolName: String
    /// Max fraction of the screen height the panel may occupy.
    let maxHeightFraction: CGFloat
    /// Bubble metrics (arrow size, corner radius, etc.).
    let metrics: MBKPanelMetrics
    /// The adopter's root SwiftUI view.
    var rootView: Content

    /// Called immediately before the panel opens.
    public var onWillShow: (() -> Void)?
    /// Called after the panel opens and an initial layout pass completes.
    public var onDidShow: (() -> Void)?
    /// Called once per close, with a boolean indicating whether the close was forced.
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    // MARK: - Assigned in setup()

    /// The NSStatusItem, created in setup().
    var statusItem: NSStatusItem!
    /// The custom NSPanel, created in setup().
    var panel: MBKPanel!
    /// Hosts the root SwiftUI view.
    /// sizingOptions = .preferredContentSize — AppKit writes pcs after every layout pass.
    var hostingController: NSHostingController<MBKPanelContentView<Content>>!
    /// Live sizing limits. maxContentHeight is @Observable — updated on open
    /// and screen change so the SwiftUI cap is always current.
    var limits: MBKPanelLimits!
    /// KVO token for hostingController.preferredContentSize.
    nonisolated(unsafe) var preferredContentSizeObservation: NSKeyValueObservation?

    // MARK: - Session state

    /// Whether setup() has been called.
    private(set) var isSetUp = false

    /// Owns all observer/monitor registrations. Non-generic to avoid spurious
    /// [#SendableMetatypes] warnings — see PanelObservers.swift for details.
    /// `nonisolated(unsafe)` so deinit (which is nonisolated) can read the
    /// observer tokens directly without a MainActor hop.
    nonisolated(unsafe) var observers: MBKPanelObservers?

    // Intentionally retained across close — the status item position is stable between
    // sessions. Only used as a fallback when buttonWindow.frame.width == 0, which is a
    // transient AppKit condition. Risk of a stale value is very low; if the user moves
    // the status item between opens, the next successful anchor read overwrites it.
    /// Last known arrow-anchor X offset, used to detect frame shifts.
    var lastKnownAnchorX: CGFloat?
    /// Cached content size, used to suppress duplicate KVO applications.
    var lastContentSize: CGSize?
    /// Prevents double-firing of onWillClose within one open session.
    var onWillCloseFired = false
    /// True once the panel has been opened at least once.
    var hasOpenedOnce = false

    // MARK: - Init

    /// @objc entry point for the status item button action.
    /// Forwards to the internal togglePanel() in PanelController+Open.swift.
    @objc func togglePanel() {
        togglePanelInternal()
    }

    /// Creates the controller with the adopter's root view, overlay gate, and appearance options.
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

    /// Performs one-time setup: sets activation policy, status item, panel window, and observers.
    public func setup() {
        precondition(!isSetUp, "MBKPanelController.setup() called more than once.")
        observers = MBKPanelObservers(controller: self)
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        // statusItem must be assigned before setupPanelWindow() — readAnchor() reads statusItem?.button.
        setupPanelWindow()
        setupWorkspaceObserver()
        setupScreenObserver()
        isSetUp = true
        mbkLog("PanelController", "setup complete")
    }

    /// Creates the panel window, glass view, hosting controller, and KVO observation.
    private func setupPanelWindow() {
        limits = MBKPanelLimits(
            maxContentHeight: liveMaxContentHeight()
        )
        mbkLog("PanelController", "setupPanelWindow -- limits created maxContentHeight=\(limits.maxContentHeight)")

        let glassView = NSGlassEffectView(frame: .zero)
        glassView.style = .regular
        // Intentionally matches the .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
        // in MBKPanelContentView.body. Both must use metrics.cornerRadius — if one changes,
        // change the other. The SwiftUI clip and the glass layer are the same shape by design.
        glassView.cornerRadius = metrics.cornerRadius
        glassView.autoresizingMask = [.width, .height]

        let kvcKeys = ["_subduedState", "_variant", "_scrimState"]
        let allKeysSupported = kvcKeys.allSatisfy {
            glassView.responds(to: NSSelectorFromString("set" + $0.prefix(1).uppercased() + $0.dropFirst() + ":"))
        }
        // Values sourced from NSGlassEffectView.h (private SPI, macOS 26).
        // _subduedState = 1 → subdued/inactive appearance (matches system panels)
        // _variant      = 1 → default panel variant
        // _scrimState   = 1 → see GlassConfig.scrimState doc above
        // responds(to:) above guards selector existence only — it cannot verify
        // that enum ordinals are stable across OS versions. If glass looks wrong
        // after an OS update, audit GlassConfig values against the updated header.
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
        // sizingOptions = .preferredContentSize — see SIZING PIPELINE in the file header.
        // With a concrete root-view type (RootEnvView) SwiftUI computes ideal height
        // correctly. AppKit writes preferredContentSize only when this option is set.
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

        // Upcast to NSViewController (non-generic) before observing so the KVO
        // closure's capture context carries no generic type parameter. Observing
        // directly on `hc: NSHostingController<Content>` would make the closure
        // @Sendable in a generic context, causing a spurious [#SendableMetatypes]
        // warning for Content.Type even though Content is never used in the body.
        // preferredContentSize is declared on NSViewController (AppKit 10.10+),
        // so the keypath and semantics are identical after the upcast.
        let vcForKVO: NSViewController = hc
        preferredContentSizeObservation = vcForKVO.observe(
            \.preferredContentSize,
            options: [.new]
        // KVO delivers on an unspecified AppKit thread. Only newSize (a value type
        // from change.newValue) is read before the Task hop — no @MainActor state
        // is accessed off-actor.
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

    /// Rounds the underlying NSThemeFrame corners to match the bubble shape.
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
        // DO NOT set masksToBounds = true — NSThemeFrame is an ancestor of
        // NSGlassEffectView. masksToBounds forces the entire window into an
        // offscreen compositing pass, severing the live backdrop connection.
        // The glass falls back to flat/washed-out. cornerRadius alone is
        // sufficient to suppress the faint square border pixel artefacts.
    }

    /// Invalidates the hosting controller's intrinsic content size, triggering re-layout.
    public func invalidateContentSize() {
        hostingController.view.invalidateIntrinsicContentSize()
    }

    /// Replaces the status item image with the given image.
    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    /// Clears the dedup caches (`lastContentSize`) so the next
    /// KVO fire on `preferredContentSize` is not suppressed by the stale size.
    /// Call this from the host app **before** a route change (e.g. settings, back,
    /// step-log) so the panel resizes to the new route's content.
    public func routeDidChange() {
        lastContentSize = nil
        mbkLog("PanelController", "routeDidChange -- cache cleared")
        guard isShown else { return }
        // Log anchor state before deferring — helps diagnose stale-buttonScreen regressions.
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

    /// Creates the NSStatusItem, configures its button image, and wires the toggle action.
    ///
    /// `sendAction(on: .leftMouseDown)` fires the action on mouseDown rather than the
    /// default mouseUp. This is required to prevent a highlight flicker on open:
    /// AppKit clears `highlight(false)` on mouseUp, so if the action fired on mouseUp
    /// the button would briefly go dark→light→dark before `openPanel()` re-asserted
    /// `highlight(true)`. Firing on mouseDown means `openPanel()` runs and locks in
    /// `highlight(true)` before AppKit's mouseUp clear cycle. See #2425.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.sendAction(on: .leftMouseDown)
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: - Deallocation

    deinit {
        preferredContentSizeObservation?.invalidate()
        preferredContentSizeObservation = nil
        // Workspace, screen, and event-monitor teardown is handled by
        // MBKPanelObservers.deinit, which fires automatically when this
        // controller releases its observers reference.
    }
}
