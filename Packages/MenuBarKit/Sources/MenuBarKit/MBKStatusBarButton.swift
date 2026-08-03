// MBKStatusBarButton.swift
// RunBot
//
// NSStatusBarButton subclass that guards highlight(false) calls while
// the panel is open. Injected via object_setClass after status item
// creation — NSStatusBarButton cannot be directly instantiated.
//
// SAFETY — BUTTON SWAP (object_setClass on the button):
//   NSStatusBarButton is a thin NSButton subclass with no extra stored ivars.
//   Adding MBKStatusBarButton adds ZERO stored ivars — isPanelOpen is backed
//   by objc_getAssociatedObject/objc_setAssociatedObject so no ivar-layout
//   mismatch can occur. See isPanelOpen implementation below.
//
// SAFETY — CELL SWAP (injectCellSubclass):
//   The cell's actual runtime class is a private AppKit subclass (e.g.
//   NSStatusBarButtonCell) with its own ivars and drawing behaviour.
//   We MUST NOT replace it with an unrelated sibling NSButtonCell subclass —
//   that discards the private class's ivars and causes appearance regressions
//   or crashes.
//
//   Instead, injectCellSubclass() reads type(of: cell) at runtime and
//   creates a one-off per-instance ISA-swap subclass of the ACTUAL private
//   cell class, injecting only the single highlight(_:withFrame:in:) method.
//   This is the exact technique Apple's KVO runtime uses — safe because:
//     • The private class's ivar layout is untouched.
//     • All drawing and tracking methods are inherited unchanged.
//     • Only one method is added on top.
//
//   The cell's back-reference to the button is stored via
//   objc_setAssociatedObject (OBJC_ASSOCIATION_ASSIGN) — no stored ivar.
//
// WHY TWO CALL PATHS MUST BE GUARDED:
//   highlight(_:) on NSButton is the public API path.
//   highlight(_:withFrame:inView:) on NSButtonCell is the internal path
//   AppKit calls directly from its mouse-tracking loop and during key-window
//   transitions — it bypasses the NSButton override entirely.
//   Both must be guarded. Diagnostic logs confirmed the button override fired
//   correctly (castOK=true, isPanelOpen flipping) while the cell path still
//   cleared the highlight. See #2440.

import AppKit
import ObjectiveC.runtime

// MARK: - Associated-object keys

// Associated-object keys must be `var` because Swift's `&` (inout) operator
// requires a mutable address. However, the value itself is never mutated —
// only the address (pointer) is used by the ObjC runtime as the key.
//
// `nonisolated(unsafe)` suppresses the #MutableGlobalVariable concurrency
// warning. The accesses are safe because:
//   • The address never changes after program start.
//   • The ObjC runtime's own internal locking protects the associated-object
//     table — no additional synchronisation is needed on our side.
// This is the standard pattern used throughout Apple's own Swift overlays
// for ObjC associated-object keys.

/// Key for the `isPanelOpen` associated object on `MBKStatusBarButton` instances.
nonisolated(unsafe) private var kIsPanelOpenKey: UInt8 = 0

/// Key for the weak button back-reference associated object on injected cell instances.
nonisolated(unsafe) private var kCellButtonKey: UInt8 = 0

// MARK: - Button

/// `NSStatusBarButton` subclass that suppresses AppKit-internal
/// `highlight(false)` calls while the panel is open.
///
/// Guards two call paths:
/// 1. `NSButton.highlight(_:)` — the public API path.
/// 2. The private cell's `highlight(_:withFrame:inView:)` — the internal path
///    AppKit uses directly during mouse tracking and key-window transitions,
///    bypassing `NSButton.highlight(_:)` entirely.
///
/// Both are required. See #2440.
final class MBKStatusBarButton: NSStatusBarButton {

    // MARK: - isPanelOpen (associated-object backed — zero stored ivars)

    /// `true` while the panel is open.
    ///
    /// Backed by `objc_getAssociatedObject` / `objc_setAssociatedObject` so
    /// that this subclass adds **zero stored ivars**. This keeps the
    /// `object_setClass` swap safe even on future OS versions where
    /// `NSStatusBarButton`'s ivar layout might change.
    var isPanelOpen: Bool {
        get {
            let val = objc_getAssociatedObject(self, &kIsPanelOpenKey) as? Bool ?? false
            mbkLog("MBKStatusBarButton", "isPanelOpen.get → \(val)")
            return val
        }
        set {
            mbkLog("MBKStatusBarButton", "isPanelOpen.set \(newValue) (was \(objc_getAssociatedObject(self, &kIsPanelOpenKey) as? Bool ?? false))")
            objc_setAssociatedObject(self, &kIsPanelOpenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - Button-level highlight guard

    /// Guards the public `NSButton.highlight(_:)` path.
    ///
    /// `setButtonHighlight(false)` sets `isPanelOpen = false` BEFORE calling
    /// `highlight(false)`, so the intended close path always passes through
    /// to `super`. Only AppKit-internal spurious calls (which arrive while
    /// `isPanelOpen` is still `true`) are swallowed.
    override func highlight(_ flag: Bool) {
        mbkLog("MBKStatusBarButton", "highlight(\(flag)) isPanelOpen=\(isPanelOpen) — " + (!flag && isPanelOpen ? "SWALLOWED" : "passing to super"))
        if !flag && isPanelOpen { return }
        super.highlight(flag)
    }

    // MARK: - Cell injection

    /// Injects a highlight guard into the button's existing cell by creating
    /// a one-off ISA-swap subclass of the cell's **actual** runtime class.
    ///
    /// Must be called once, after `object_setClass` has already swapped the
    /// button's own isa to `MBKStatusBarButton`.
    ///
    /// The injected subclass:
    /// - Is a direct subclass of whatever private class the cell already is
    ///   (e.g. `NSStatusBarButtonCell`).
    /// - Adds only `highlight(_:withFrame:in:)` — nothing else.
    /// - Adds zero stored ivars; the back-reference uses `objc_setAssociatedObject`.
    ///
    /// This is the same ISA-swap technique used by KVO internally.
    func injectCellSubclass() {
        guard let cell = self.cell else {
            mbkLog("MBKStatusBarButton", "injectCellSubclass -- cell is nil, skipping")
            return
        }

        let originalClass: AnyClass = type(of: cell)
        let originalClassName = NSStringFromClass(originalClass)
        mbkLog("MBKStatusBarButton", "injectCellSubclass -- cell originalClass=\(originalClassName)")

        // Build a deterministic per-instance subclass name so repeated calls
        // (e.g. if AppKit re-vends the cell) reuse the same class rather than
        // leaking a new class pair every time.
        let subclassName = "MBKStatusBarButtonCell_" + originalClassName

        let subclass: AnyClass
        if let existing = NSClassFromString(subclassName) {
            mbkLog("MBKStatusBarButton", "injectCellSubclass -- reusing existing subclass \(subclassName)")
            subclass = existing
        } else {
            guard let newPair = objc_allocateClassPair(originalClass, subclassName, 0) else {
                mbkLog("MBKStatusBarButton", "injectCellSubclass -- objc_allocateClassPair failed for \(subclassName), aborting")
                return
            }

            // The selector and type encoding for highlight(_:withFrame:in:).
            let sel = #selector(NSButtonCell.highlight(_:withFrame:in:))

            // We need the type encoding from the method on the original class
            // (it may differ from NSButtonCell's encoding on private subclasses).
            guard let existingMethod = class_getInstanceMethod(originalClass, sel) else {
                mbkLog("MBKStatusBarButton", "injectCellSubclass -- could not find method \(sel) on \(originalClassName), aborting")
                objc_disposeClassPair(newPair)
                return
            }
            let typeEncoding = method_getTypeEncoding(existingMethod)

            // Build the IMP using a block. The block captures nothing from
            // the outer scope — it reads the back-reference via
            // objc_getAssociatedObject at call time so it stays valid even
            // if the cell outlives the controller.
            //
            // Signature: (id self, SEL _cmd, BOOL flag, NSRect frame, NSView *view)
            typealias HighlightIMP = @convention(c) (AnyObject, Selector, Bool, NSRect, NSView) -> Void

            let imp: IMP = imp_implementationWithBlock({ (cellSelf: AnyObject, flag: Bool, frame: NSRect, view: NSView) -> Void in
                let btn = objc_getAssociatedObject(cellSelf, &kCellButtonKey) as? MBKStatusBarButton
                let panelOpen = btn?.isPanelOpen ?? false
                mbkLog("MBKStatusBarButtonCell", "highlight(\(flag), withFrame:, in:) isPanelOpen=\(panelOpen) btn=\(btn != nil ? "ok" : "nil") — " + (!flag && panelOpen ? "SWALLOWED" : "passing to super"))
                if !flag && panelOpen { return }

                // Call the original class's implementation (not NSButtonCell's —
                // we need the private subclass's own drawing to run).
                let superIMP = class_getMethodImplementation(originalClass, sel)
                unsafeBitCast(superIMP, to: HighlightIMP.self)(cellSelf, sel, flag, frame, view)
            } as @convention(block) (AnyObject, Bool, NSRect, NSView) -> Void)

            class_addMethod(newPair, sel, imp, typeEncoding)
            objc_registerClassPair(newPair)
            mbkLog("MBKStatusBarButton", "injectCellSubclass -- registered new subclass \(subclassName)")
            subclass = newPair
        }

        // Swap the cell's isa to the new subclass.
        let beforeCell = NSStringFromClass(type(of: cell as AnyObject))
        object_setClass(cell, subclass)
        let afterCell = NSStringFromClass(type(of: cell as AnyObject))
        mbkLog("MBKStatusBarButton", "injectCellSubclass -- cell isa: \(beforeCell) → \(afterCell) castOK=\(NSStringFromClass(type(of: cell as AnyObject)) == subclassName)")

        // Store the weak back-reference via associated object — no stored ivar.
        objc_setAssociatedObject(cell, &kCellButtonKey, self, .OBJC_ASSOCIATION_ASSIGN)
        mbkLog("MBKStatusBarButton", "injectCellSubclass -- back-reference set btnAddr=\(UInt(bitPattern: ObjectIdentifier(self)))")
    }
}
