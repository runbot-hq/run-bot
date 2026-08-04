// MBKStatusBarButton.swift
// RunBot
//
// Keeps the status bar button visually highlighted ("pressed") while the
// panel is open, and restores normal highlight behaviour when it closes.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE PROBLEM
// ─────────────────────────────────────────────────────────────────────────────
//
//   A macOS menu-bar app convention: the status bar button stays highlighted
//   (the pill appears pressed/active) for the entire time the panel is visible.
//   AppKit does NOT do this automatically — it clears the highlight as soon as
//   the mouse button is released.
//
//   Worse, AppKit clears the highlight through TWO independent call paths, and
//   they must both be intercepted:
//
//   PATH 1 — NSButton.highlight(_:)
//     The standard public override point. AppKit calls this e.g. on key-window
//     change. Overriding it is necessary but not sufficient.
//
//   PATH 2 — NSButtonCell.highlight(_:withFrame:inView:)
//     Called DIRECTLY by AppKit's internal mouse-tracking loop inside the cell.
//     This path completely bypasses PATH 1 — NSButton.highlight(_:) is never
//     called during mouse tracking. This is the primary path that clears the
//     highlight on mouseUp.
//
//   Confirmed by logs during #2440 investigation: PATH 1 fired correctly
//   (castOK=true, isPanelOpen flipping as expected) while the highlight still
//   cleared — proving PATH 2 was firing independently and winning the race.
//
// ─────────────────────────────────────────────────────────────────────────────
// APPROACHES TRIED AND REJECTED (do not re-introduce)
// ─────────────────────────────────────────────────────────────────────────────
//
//   1. isHighlighted = true after close / on a timer
//      Reactive — always at least one frame behind. Produces a visible
//      flash: button goes dark → light → dark. Rejected.
//
//   2. Override NSButton.highlight(_:) only (PATH 1)
//      Blocks the key-window-change path but NOT the mouse-tracking path.
//      Logs confirmed PATH 1 fired and was guarded correctly, yet the
//      highlight still cleared via PATH 2. Insufficient alone.
//
//   3. NSEvent global monitor for mouseUp
//      By the time the monitor fires, AppKit has already run the cell's
//      tracking loop and called highlight(false). Too late.
//
//   4. sendEvent intercept
//      Status bar button events do not flow through NSApplication.sendEvent —
//      the private status bar window handles its own dispatch. Unreachable.
//
//   5. setButtonType(.toggle) / .onOff
//      Changes button selection-state semantics, not highlight rendering.
//      AppKit still clears the pressed appearance on mouseUp regardless.
//
//   6. Replace NSStatusItem with a fully custom NSView
//      Conceptually simpler but requires reimplementing: the native pill
//      appearance (rendered by private NSStatusBarButtonCell drawing code),
//      template image tinting, accessibility, and menu-bar auto-sizing.
//      More code, worse fidelity. Rejected.
//
//   7. Replacing cell with MBKStatusBarButtonCell: NSButtonCell  (pre-#2441)
//      object_setClass(cell, MBKStatusBarButtonCell.self) where
//      MBKStatusBarButtonCell was a direct NSButtonCell subclass.
//      This replaced the private NSStatusBarButtonCell — a sibling class —
//      discarding all of Apple's private ivars and drawing logic.
//      Only avoided crashes by luck. Appearance regressions possible.
//      Removed in #2441.
//
//   8. OBJC_ASSOCIATION_ASSIGN for the cell back-reference  (pre-#2441 review)
//      Stores a raw unretained pointer — NOT a weak reference. If the button
//      is deallocated before the cell, the IMP's objc_getAssociatedObject
//      call would return a dangling pointer; the subsequent as? cast does not
//      protect against reading freed memory. Fixed by WeakBox (see below).
//      ❌ Reviewed and explicitly rejected. Do not revert to ASSIGN.
//
// ─────────────────────────────────────────────────────────────────────────────
// CURRENT SOLUTION — TWO object_setClass SWAPS
// ─────────────────────────────────────────────────────────────────────────────
//
//   SWAP 1 — The button itself:
//     object_setClass(button, MBKStatusBarButton.self)
//     Safe because NSStatusBarButton has no extra stored ivars beyond NSButton,
//     and MBKStatusBarButton adds ZERO stored ivars (isPanelOpen uses
//     associated objects — see below). Overrides highlight(_:) for PATH 1.
//
//   SWAP 2 — The button's cell (injectCellSubclass):
//     The cell's actual runtime class is a private Apple class, typically
//     NSStatusBarButtonCell (not NSButtonCell). We MUST subclass the ACTUAL
//     private class, not an unrelated sibling — replacing it with an unrelated
//     sibling discards the private class's ivars and drawing behaviour.
//
//     injectCellSubclass() does this by:
//       a. Reading type(of: cell) at runtime to get the actual private class.
//       b. Creating a one-off subclass of that class via objc_allocateClassPair.
//          The subclass name is deterministic ("MBKStatusBarButtonCell_" +
//          originalClassName) so repeated calls reuse the same class instead
//          of leaking a new class pair each time.
//       c. Injecting only highlight(_:withFrame:in:) via imp_implementationWithBlock.
//          All other methods and the entire ivar layout are inherited unchanged.
//       d. Calling object_setClass(cell, dynamicSubclass) to swap the isa.
//       e. Storing a zeroing-weak back-reference to the button via a WeakBox
//          retained by objc_setAssociatedObject, so the IMP can read
//          isPanelOpen without a stored ivar on the cell. If the button is
//          deallocated before the cell (unexpected but possible in future
//          refactors), box.value is nil and the IMP safely no-ops.
//
//     The IMP calls class_getMethodImplementation(originalClass, sel) to dispatch
//     to the ORIGINAL private class's own implementation — not NSButtonCell's —
//     so Apple's native pill-shaped drawing is fully preserved on pass-through.
//
//     This is the exact technique Apple's KVO runtime uses internally: create a
//     secret subclass, swap the isa, inject one override, inherit everything else.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY isPanelOpen USES ASSOCIATED OBJECTS (not a stored ivar)
// ─────────────────────────────────────────────────────────────────────────────
//
//   object_setClass is only safe when the new class adds no stored ivars — the
//   ObjC runtime allocates instance memory based on the ORIGINAL class's ivar
//   layout at alloc time; there is no space for new ivars in an existing instance.
//   Adding a stored ivar to MBKStatusBarButton would produce out-of-bounds writes
//   on every access, with undefined behaviour (usually a crash or memory
//   corruption in an unrelated object).
//
//   Associated objects (objc_setAssociatedObject / objc_getAssociatedObject)
//   store values in a side table keyed by the object pointer + a key pointer.
//   They add nothing to the instance layout and are therefore safe to use after
//   an object_setClass swap.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY ASSOCIATED-OBJECT KEYS ARE nonisolated(unsafe) var, NOT let
// ─────────────────────────────────────────────────────────────────────────────
//
//   The ObjC runtime uses the *memory address* of the key variable as the
//   dictionary key — it never reads or writes the value stored there.
//   Only the address matters, and it is fixed from binary load time.
//
//   Swift's & (inout) operator — required to pass the address — requires the
//   operand to be `var`. But a bare module-level `var` triggers Swift's
//   #MutableGlobalVariable concurrency error.
//
//   `nonisolated(unsafe)` is the correct suppression: it tells the concurrency
//   checker that an external mechanism (the ObjC runtime's own internal lock
//   on the associated-object table) protects all accesses. The `unsafe` does
//   not reflect a real safety risk here — the value is never mutated.
//   This is the standard pattern used in Apple's own Swift overlays.
//
// ─────────────────────────────────────────────────────────────────────────────
// CALL-SITE CONTRACT (PanelController+Open.swift)
// ─────────────────────────────────────────────────────────────────────────────
//
//   setButtonHighlight(true)  — called on open:
//     1. button.isPanelOpen = true    (arm the guard)
//     2. button.highlight(true)       (light up the pill)
//
//   setButtonHighlight(false) — called on close:
//     1. button.isPanelOpen = false   (DISARM the guard FIRST)
//     2. button.highlight(false)      (clear the pill)
//
//   The order in the close path is critical: isPanelOpen must be false before
//   highlight(false) is called, otherwise the button's own override swallows
//   the intended clear. Any AppKit-internal highlight(false) calls that arrive
//   while isPanelOpen is true are the spurious ones and are correctly swallowed.

import AppKit
import ObjectiveC.runtime

// MARK: - WeakBox

/// Wraps a weak reference for storage in an associated-object value slot.
///
/// `objc_setAssociatedObject` with `OBJC_ASSOCIATION_RETAIN_NONATOMIC` retains
/// the box itself; the box's `value` property is a zeroing `weak var` that
/// ARC zeroes automatically when the referent is deallocated.
///
/// This pattern is required because `OBJC_ASSOCIATION_WEAK_NONATOMIC` is not
/// reliably available through the Swift/ObjC bridge on all supported OS versions.
final class WeakBox<T: AnyObject> {
    /// The wrapped object; zeroed by ARC when the referent is deallocated.
    weak var value: T?
    /// Creates a box holding a zeroing-weak reference to `value`.
    init(_ value: T) { self.value = value }
}

// MARK: - Associated-object keys

// See "WHY ASSOCIATED-OBJECT KEYS ARE nonisolated(unsafe) var" in the file
// header above before changing these declarations.

/// Key for the `isPanelOpen` associated object on `MBKStatusBarButton` instances.
nonisolated(unsafe) private var kIsPanelOpenKey: UInt8 = 0

/// Key for the `WeakBox<MBKStatusBarButton>` associated object on injected cell instances.
nonisolated(unsafe) private var kCellButtonKey: UInt8 = 0

// MARK: - Button

/// `NSStatusBarButton` subclass that suppresses AppKit-internal
/// `highlight(false)` calls while the panel is open.
///
/// Injected via `object_setClass` in `PanelController.setupStatusItem()` —
/// `NSStatusBarButton` cannot be directly instantiated.
///
/// Guards two independent AppKit call paths (both are required — see file header):
/// 1. `NSButton.highlight(_:)` — public API / key-window-change path.
/// 2. Cell's `highlight(_:withFrame:inView:)` — internal mouse-tracking path
///    that bypasses path 1 entirely. Intercepted via `injectCellSubclass()`.
///
/// See #2440 (investigation), #2441 (fix).
final class MBKStatusBarButton: NSStatusBarButton {

    // MARK: - isPanelOpen

    /// `true` while the panel is open; arms/disarms the highlight guard.
    ///
    /// Backed by `objc_getAssociatedObject` / `objc_setAssociatedObject` —
    /// adds **zero stored ivars** to the class, which is required for
    /// `object_setClass` safety. See file header "WHY isPanelOpen USES
    /// ASSOCIATED OBJECTS" for the full rationale. Do not convert this to
    /// a stored property — doing so would make the `object_setClass` swap
    /// unsafe (out-of-bounds ivar write on every access).
    ///
    /// - Important: On close, set `isPanelOpen = false` **before** calling
    ///   `highlight(false)`. See CALL-SITE CONTRACT in the file header.
    var isPanelOpen: Bool {
        get {
            // No log here — this getter is called on every highlight(_:) and
            // every cell mouse-tracking tick; logging would be hot-path noise.
            return objc_getAssociatedObject(self, &kIsPanelOpenKey) as? Bool ?? false
        }
        set {
            mbkLog("MBKStatusBarButton", "isPanelOpen.set \(newValue) (was \(objc_getAssociatedObject(self, &kIsPanelOpenKey) as? Bool ?? false))")
            objc_setAssociatedObject(self, &kIsPanelOpenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - PATH 1 guard — NSButton.highlight(_:)

    /// Guards the public `NSButton.highlight(_:)` path (PATH 1).
    ///
    /// Swallows `highlight(false)` while `isPanelOpen` is `true`.
    /// The close path in `setButtonHighlight(false)` sets `isPanelOpen = false`
    /// first, so the intended clear always passes through.
    ///
    /// PATH 2 (cell mouse-tracking) is handled by `injectCellSubclass()`.
    override func highlight(_ flag: Bool) {
        mbkLog("MBKStatusBarButton", "highlight(\(flag)) isPanelOpen=\(isPanelOpen) — " + (!flag && isPanelOpen ? "SWALLOWED" : "passing to super"))
        if !flag && isPanelOpen { return }
        super.highlight(flag)
    }

    // MARK: - PATH 2 guard — cell ISA-swap

    /// Guards the internal cell `highlight(_:withFrame:inView:)` path (PATH 2)
    /// by ISA-swapping the button's cell to a dynamically created subclass of
    /// the cell's **actual** private runtime class.
    ///
    /// ## Why this is necessary
    /// AppKit's mouse-tracking loop calls `highlight(_:withFrame:inView:)`
    /// directly on the cell, bypassing `NSButton.highlight(_:)` entirely.
    /// Overriding only PATH 1 is insufficient — PATH 2 still clears the
    /// highlight on every mouseUp. See #2440.
    ///
    /// ## Why we subclass the actual private class (not NSButtonCell)
    /// The cell's runtime class is a private Apple class (typically
    /// `NSStatusBarButtonCell`), not `NSButtonCell`. Replacing it with an
    /// unrelated `NSButtonCell` subclass discards all of Apple's private ivars
    /// and drawing behaviour — appearance regressions and potential crashes.
    /// We must subclass the class that is actually there.
    ///
    /// ## How the ISA-swap works
    /// 1. Read `type(of: cell)` — get the actual private class at runtime.
    /// 2. `objc_allocateClassPair` — create a subclass of that class.
    ///    Name is deterministic (`"MBKStatusBarButtonCell_" + originalName`)
    ///    so repeated calls reuse the same class (no class-pair leak).
    /// 3. `imp_implementationWithBlock` — build the guard IMP.
    ///    The IMP reads `isPanelOpen` via a retained `WeakBox` and either
    ///    returns early (swallow) or calls the **original private class's own IMP**
    ///    via `class_getMethodImplementation(originalClass, sel)` — preserving
    ///    Apple's native pill drawing on the pass-through path.
    /// 4. `class_addMethod` + `objc_registerClassPair` — register the subclass.
    /// 5. `object_setClass(cell, dynamicSubclass)` — swap the cell's isa.
    /// 6. Store a `WeakBox<MBKStatusBarButton>` via `OBJC_ASSOCIATION_RETAIN_NONATOMIC`
    ///    so the IMP can reach `isPanelOpen` without a stored ivar on the cell.
    ///    If the button is deallocated before the cell, `box.value` is `nil`
    ///    and the IMP safely treats `isPanelOpen` as `false` (pass-through).
    ///
    /// This is the same ISA-swap technique Apple's KVO runtime uses internally.
    ///
    /// ## Call-site requirement
    /// Must be called **after** `object_setClass(button, MBKStatusBarButton.self)`
    /// so the button is already `MBKStatusBarButton` when the back-reference
    /// is stored.
    ///
    /// ## One-time setup
    /// Designed to be called exactly once per status item, from `setupStatusItem()`.
    /// If the status item is torn down and a new cell is vended by AppKit, this must
    /// be called again on the new cell instance — the dynamic subclass (class pair)
    /// is reused via `NSClassFromString`, but `object_setClass` and the `WeakBox`
    /// store always run for the current cell instance regardless of which path
    /// (new or reused class) is taken.
    func injectCellSubclass() {
        guard let cell = self.cell else {
            mbkLog("MBKStatusBarButton", "injectCellSubclass -- cell is nil, skipping")
            return
        }

        let originalClass: AnyClass = type(of: cell)
        let originalClassName = NSStringFromClass(originalClass)
        mbkLog("MBKStatusBarButton", "injectCellSubclass -- cell originalClass=\(originalClassName)")

        // Deterministic name: reuse the class on repeated calls instead of
        // allocating a new class pair each time (class pairs are never freed).
        let subclassName = "MBKStatusBarButtonCell_" + originalClassName

        // IMP calling convention — applies to the block below.
        //
        // imp_implementationWithBlock wraps an ObjC block as a C IMP.
        // The ObjC runtime calls all IMPs as: (self, _cmd, arg1, arg2, ...)
        // imp_implementationWithBlock handles _cmd INTERNALLY — it does NOT
        // inject a Selector into the block's parameter list.
        // The block therefore receives exactly: (self, arg1, arg2, ...)
        //   → (cellSelf, flag, frame, view)   ← correct, 4 params
        //
        // WARNING: do NOT add a Selector parameter to this block. Doing so
        // would shift every argument by one — flag would receive the selector
        // value, frame would receive flag, and so on.
        //
        // HighlightIMP (5 params including Selector) is used only for the
        // unsafeBitCast super-dispatch call, which IS a raw C IMP invocation.
        //
        // mbkLog inside the IMP fires on every mouse-tracking tick while the
        // button is hovered. This is a no-op in release: the default
        // mbkLogHandler is #if DEBUG-gated in Logging.swift. It is only
        // noisy if the host app installs a custom handler without a debug guard.
        typealias HighlightIMP = @convention(c) (AnyObject, Selector, Bool, NSRect, NSView) -> Void

        let subclass: AnyClass
        if let existing = NSClassFromString(subclassName) {
            // The class pair is already registered — skip objc_allocateClassPair
            // and class_addMethod. The object_setClass and WeakBox store below
            // still run unconditionally: they operate on the current cell
            // instance, not the class, so they are always required regardless
            // of whether the class is new or reused.
            //
            // Note: `is MBKStatusBarButtonCell_Xyz` cannot be used here because
            // the subclass name — and therefore the type — is only known at
            // runtime. The NSClassFromString lookup and the afterCell string
            // comparison below are the correct and only available checks.
            mbkLog("MBKStatusBarButton", "injectCellSubclass -- reusing existing subclass \(subclassName)")
            subclass = existing
        } else {
            guard let newPair = objc_allocateClassPair(originalClass, subclassName, 0) else {
                mbkLog("MBKStatusBarButton", "injectCellSubclass -- objc_allocateClassPair failed for \(subclassName), aborting")
                return
            }

            let sel = #selector(NSButtonCell.highlight(_:withFrame:in:))

            // Read the type encoding from the ORIGINAL class, not NSButtonCell.
            // Private subclasses may use a different encoding; using the wrong
            // one causes silent misbehaviour in the ObjC runtime's dispatch.
            guard let existingMethod = class_getInstanceMethod(originalClass, sel) else {
                mbkLog("MBKStatusBarButton", "injectCellSubclass -- could not find method \(sel) on \(originalClassName), aborting")
                objc_disposeClassPair(newPair)
                return
            }

            // method_getTypeEncoding returns Optional. nil means the ObjC runtime
            // would register the method with no type info — selector dispatch
            // may behave unexpectedly. Guard explicitly.
            guard let typeEncoding = method_getTypeEncoding(existingMethod) else {
                mbkLog("MBKStatusBarButton", "injectCellSubclass -- nil typeEncoding for \(sel) on \(originalClassName), aborting")
                objc_disposeClassPair(newPair)
                return
            }

            // sel2 aliases sel so the IMP block captures it by value.
            // Selector is a value type (OpaquePointer-backed); capture-by-value
            // is safe and correct — no retain or heap allocation involved.
            let sel2 = sel
            let imp: IMP = imp_implementationWithBlock({ (cellSelf: AnyObject, flag: Bool, frame: NSRect, view: NSView) in
                // WeakBox.value is nil if the button was already deallocated —
                // treat isPanelOpen as false (safe pass-through).
                let btn = (objc_getAssociatedObject(cellSelf, &kCellButtonKey) as? WeakBox<MBKStatusBarButton>)?.value
                let panelOpen = btn?.isPanelOpen ?? false
                let verdict = !flag && panelOpen ? "SWALLOWED" : "passing to super"
                mbkLog("MBKStatusBarButtonCell", "highlight(\(flag), withFrame:, in:) isPanelOpen=\(panelOpen) btn=\(btn != nil ? "ok" : "nil") — \(verdict)")
                if !flag && panelOpen { return }

                // Dispatch to the ORIGINAL private class's IMP, not NSButtonCell's.
                // This preserves Apple's native pill-shaped drawing on every
                // pass-through call.
                //
                // `view` is typed NSView (non-optional) per AppKit's documented
                // contract for highlight(_:withFrame:in:). If AppKit ever passes
                // nil here, this unsafeBitCast call is the crash site — change
                // NSView to AnyObject at that point.
                let superIMP = class_getMethodImplementation(originalClass, sel2)
                unsafeBitCast(superIMP, to: HighlightIMP.self)(cellSelf, sel2, flag, frame, view)
            } as @convention(block) (AnyObject, Bool, NSRect, NSView) -> Void)

            class_addMethod(newPair, sel, imp, typeEncoding)
            objc_registerClassPair(newPair)
            mbkLog("MBKStatusBarButton", "injectCellSubclass -- registered new subclass \(subclassName)")
            subclass = newPair
        }

        // ISA-swap the cell to the subclass (new or reused).
        // Both paths (new class and reused class) reach this point — these
        // two operations are per-instance, not per-class, and must run every
        // time injectCellSubclass is called regardless of whether the class
        // pair was just created or already existed.
        let beforeCell = NSStringFromClass(type(of: cell as AnyObject))
        object_setClass(cell, subclass)
        let afterCell = NSStringFromClass(type(of: cell as AnyObject))
        mbkLog("MBKStatusBarButton", "injectCellSubclass -- cell isa: \(beforeCell) → \(afterCell) castOK=\(afterCell == subclassName)")

        // Zeroing-weak back-reference via WeakBox retained by the associated-object
        // table. If the button is deallocated before the cell, box.value becomes nil
        // and the IMP safely no-ops rather than dereferencing a dangling pointer.
        // ❌ OBJC_ASSOCIATION_ASSIGN was reviewed and explicitly rejected — it stores
        // a raw unretained pointer with no zeroing on deallocation (dangling-ptr UB).
        // Do not revert to ASSIGN. See approach 8 in the file header.
        let box = WeakBox(self)
        objc_setAssociatedObject(cell, &kCellButtonKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        mbkLog("MBKStatusBarButton", "injectCellSubclass -- back-reference set btnAddr=\(UInt(bitPattern: ObjectIdentifier(self)))")
    }
}
