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
// HOW THE WINDOW IS LAYERED (back to front):
//   contentView = NSGlassEffectView   (direct — no wrapper)
//     └── view    NSHostingController.view  (adopter SwiftUI tree)
//
//   NSGlassEffectView MUST be the direct panel.contentView.
//   ❌ NEVER put an NSVisualEffectView back in this window.
//   ❌ NEVER wrap NSGlassEffectView in any intermediate NSView.
//   ❌ NEVER wrap the hosted tree in `.glassEffect(...)`.
//   ❌ NEVER reintroduce NSPopover.
//
// SIZING PIPELINE:
//   MBKPanelContentView inner VStack onGeometryChange
//     → onSizeChange closure (set in setupPanelWindow)
//     → applyMeasuredSize(_:)  [PanelController+Frame.swift]
//     → applyFrame(content:reason:)
//     → panel.setFrame
//
//   On open: layoutSubtreeIfNeeded() forces SwiftUI to settle so
//   onGeometryChange fires synchronously before the panel is visible.
//
// FILE ORGANISATION:
//   PanelController.swift            — stored properties, init, setup, deinit
//   PanelController+Frame.swift      — anchor reading and the frame pipeline
//   PanelController+Open.swift       — toggle/open/close, highlight
//   PanelController+Observers.swift  — workspace, screen, mouse and key monitors

import AppKit
import SwiftUI

@MainActor
public final class MBKPanelController: NSObject, MBKPanelControllerProtocol {

    // MARK: - Constants

    static let fallbackContentSize = CGSize(width: 320, height: 240)

    // MARK: - Configuration

    let overlayGate: MBKOverlayGate
    private let symbolName: String
    let maxHeightFraction: CGFloat
    let metrics: MBKPanelMetrics
    var rootView: AnyView

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    // MARK: - Assigned in setup()

    var statusItem: NSStatusItem!
    var panel: MBKPanel!
    var hostingController: NSHostingController<MBKPanelContentView>!
    var limits: MBKPanelLimits!

    // MARK: - Session state

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
        mbkLog("PanelController", "setupPanelWindow -- limits created")

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
                + " \(ProcessInfo.processInfo.operatingSystemVersionString)")
        }

        var contentView = MBKPanelContentView(
            limits: limits,
            metrics: metrics,
            content: rootView
        )
        contentView.onSizeChange = { [weak self] size in
            guard let self else { return }
            mbkLog("PanelController", "onGeometryChange fired -- naturalSize=(\(size.width),\(size.height)) isShown=\(self.isShown)")
            self.applyMeasuredSize(size)
        }

        let hc = NSHostingController(rootView: contentView)
        // sizingOptions = [] — we measure via onGeometryChange, not preferredContentSize.
        // No intrinsicContentSize path, no feedback loop.
        hc.sizingOptions = []
        let hv = hc.view
        hv.translatesAutoresizingMaskIntoConstraints = false
        hv.wantsLayer = true
        hv.layer?.backgroundColor = CGColor.clear
        hostingController = hc
        mbkLog("PanelController", "setupPanelWindow -- hostingController created sizingOptions=[]")

        glassView.addSubview(hv)
        // Three-edge pins: leading, trailing, top.
        // No bottom pin needed — onGeometryChange fires on natural content size,
        // not on window size. No re-proposal required.
        NSLayoutConstraint.activate([
            hv.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hv.topAnchor.constraint(equalTo: glassView.topAnchor),
        ])
        mbkLog("PanelController", "setupPanelWindow -- three-edge AL pins activated (leading, trailing, top)")

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
        var contentView = MBKPanelContentView(limits: limits, metrics: metrics, content: rootView)
        contentView.onSizeChange = { [weak self] size in
            guard let self else { return }
            mbkLog("PanelController", "onGeometryChange fired (setRootView) -- naturalSize=(\(size.width),\(size.height))")
            self.applyMeasuredSize(size)
        }
        hostingController.rootView = contentView
        mbkLog("PanelController", "setRootView -- rootView replaced, lastContentSize cleared")
    }

    public func invalidateContentSize() {
        mbkLog("PanelController", "invalidateContentSize -- forcing layout pass to re-trigger onGeometryChange")
        hostingController.view.layoutSubtreeIfNeeded()
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
