## Contents

- [Why NSPopover Instead of NSPanel](#why-nspopover-instead-of-nspanel)
- [Preventing Side-Jump on Resize](#preventing-side-jump-on-resize)
- [Dismiss, Sheets, and File Pickers](#dismiss-sheets-and-file-pickers)

# NSPopover — UI Decisions

Everything you need to know before touching `AppDelegate.swift`,
`AppDelegate+PanelSetup.swift`, `PopoverView.swift`, or any
sizing/frame/contentSize code in this project.

**Read this entire document before writing a single line.**

---

## Why NSPopover Instead of NSPanel

> Issue: #1017 — SettingsView gets rectangular corners when a SwiftUI `.sheet` is presented

### The core problem

When a SwiftUI `.sheet` (e.g. `RunnerDetailPopover`, `ScopeEditSheet`, `AddRunnerSheet`) is
presented on top of `SettingsView`, the **parent window** — not the sheet — loses its rounded
corners and goes fully rectangular.

This is **not** a bug in RunBot’s logic. It is a well-known consequence of how AppKit handles
sheet presentation on windows that rely on any form of *custom* corner radius.

When AppKit calls `window.beginSheet(sheet)` it:
1. Adds the sheet as a child `NSWindow` via `addChildWindow(_:ordered:)` (or the newer
   `NSWindowAttachmentBehavior` path on macOS 14+).
2. To composite the two windows, it modifies the **parent window’s `CALayer` tree** — in
   particular the `masksToBounds` and `mask` properties on the content view’s backing layer.
3. Any `CAShapeLayer` mask or `cornerRadius + masksToBounds` that *you* set on that layer is
   removed or invalidated by AppKit as a side-effect.

This is documented nowhere publicly, but is confirmed by multiple developer reports:
- https://github.com/runbot-hq/run-bot/issues/1017
- https://stackoverflow.com/questions/62995489 (clear bg + borderless doesn’t survive sheet)
- Electron issue #9159 (same root cause in a different runtime)

### What was tried and failed

**Attempt 1 — `CAShapeLayer` mask on `NSVisualEffectView`** (`PanelChromeView`)

Drew a custom Bézier path (rounded rect + arrow tip) as a `CAShapeLayer` and applied it as
`fxView.layer.mask`. AppKit removes/replaces `layer.mask` on the parent window’s content view
when a sheet is attached. The panel body went rectangular immediately on sheet presentation.

**Attempt 2 — `contentView.layer.cornerRadius + masksToBounds`** (PR #1017 first iteration)

Removed `PanelChromeView` and set `cornerRadius` + `masksToBounds` directly on the
`NSHostingController.view`. `masksToBounds = true` is precisely what AppKit modifies during
sheet attachment. Same result. Also: `masksToBounds` clips child `NSWindow`s’ visual content.

**Attempt 3 — `backgroundColor = .clear + isOpaque = false`** (“window-server native corners”)

Made the panel fully transparent, relying on the window server to draw native rounded corners.
Failed because a borderless `NSPanel` with `backgroundColor = .clear` does NOT get
window-server native rounded corners. That behaviour only applies to windows with a standard
(non-borderless) style mask. The transparency just made the rectangle invisible — the issue
was never fixed, just hidden in the zero-sheet state.

**Attempt 4 — `.background(.regularMaterial)` on `PanelMainView`**

Added vibrancy back after removing `PanelChromeView`. No rounding — the window layer has no
corner radius, so the material renders as a plain rectangle regardless.

### Root cause

All attempts share the same flaw: they try to apply corner rounding *inside the window’s view
hierarchy*. AppKit deliberately discards or overrides any such in-hierarchy clipping when a
sheet is presented. **The only correct solution is to never let the parent window’s own layers
be responsible for rounding.**

### The solution: NSPopover

`NSPopover` uses `NSPopoverWindowFrame`, a dedicated window class whose chrome is drawn by the
window-server compositor — completely unaffected by sheet attachment. Rounded corners survive
`.sheet` natively with zero extra code.

This is how every well-maintained macOS status bar app works: Raycast, Proxyman, Hand Mirror,
Longo, Almighty. The canonical Apple tutorial also uses `NSPopover`.

```
❌ NEVER revert to NSPanel without understanding the .sheet corner regression.
```

---

## Preventing Side-Jump on Resize

> Regression guard ref: issues #377, #1017  
> See also: `AppDelegate.swift`, `PopoverSizeObserver.swift`

### The one rule

**Call `popover.show(relativeTo:of:preferredEdge:)` exactly once per open.** Never call it
again while the popover is visible. Every side-jumping bug in this codebase’s history has
violated this rule.

### Why jumping happens

`NSPopover` has two completely independent concepts:

| Concept | API | What it controls |
|---|---|---|
| **Anchor** | `popover.show(relativeTo:of:preferredEdge:)` | Where the arrow attaches. Recalculated from scratch on every call. |
| **Size** | `popover.contentSize` | How big the popover body is. Pure resize around the fixed anchor. |

Every time you call `show()`, AppKit recomputes the anchor geometry from the current
`button.bounds` and the *current* `contentSize`. If the size has changed since the last
`show()`, the anchor lands in a slightly different horizontal position — that’s the jump.

### The correct pattern

```swift
// AppDelegate.swift — openPanel()
// Called ONCE when the user clicks the status bar button.
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

// PopoverSizeObserver.swift — KVO callback
// Called whenever SwiftUI changes preferredContentSize.
// NEVER calls show() again.
popover.contentSize = NSSize(width: newWidth, height: newHeight)
```

`contentSize` resizes the body in-place. The arrow never moves.

### `animates = false` is not optional

With `animates = true` (AppKit default), every `contentSize` write starts a 200 ms Core
Animation resize. If SwiftUI fires multiple `preferredContentSize` KVO updates in one layout
pass (it does), you get overlapping animations, stuttering, and apparent jumps.

```swift
popover.animates = false   // set this at init time, never change it
```

### Common mistakes

```swift
// ❌ WRONG — re-anchors the popover every time the size changes
func updateSize(_ size: CGSize) {
    popover.contentSize = size
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
}

// ❌ WRONG — bypasses AppKit geometry; anchor recalculates on next event tick
popover.contentViewController?.view.window?.setFrame(newFrame, display: true)

// ❌ WRONG — NSPanel.setFrame() couples position + size; always repositions
panel.setFrame(NSRect(origin: currentOrigin, size: newSize), display: true)
```

| Mistake | Why it jumps |
|---|---|
| Calling `popover.show()` again on resize | `show()` re-runs full anchor calculation from scratch |
| `behavior = .transient` with size changes | Transient mode can close and re-show automatically in some AppKit paths |
| Setting `contentSize` before `show()` with wrong size | Popover opens at wrong size; `show()` is called again to “fix” it |
| `NSWindow.setFrame()` on the popover’s window | Bypasses AppKit geometry; anchor recalculates on next event loop tick |

### History of this bug

| Commit / PR | What broke | Root cause |
|---|---|---|
| Pre-NSPopover migration | Jump on every resize | `NSPanel.setFrame()` couples position and size |
| First NSPopover attempt | Jump on tab switch | `show()` called in the resize observer |
| #1017 workaround attempt | Jump on sheet present | `show()` called to “reposition after promotion” |

### Checklist before merging any PR that touches popover code

- [ ] `popover.show()` is called in exactly one place (the status bar button action)
- [ ] No resize/layout observer calls `show()`
- [ ] `popover.animates` is `false`
- [ ] `contentSize` is the only API used for size changes while the popover is open
- [ ] Tested: open popover, trigger a size change (switch tab, load data), confirm no horizontal shift

```
❌ NEVER re-call popover.show() on resize.
```

---

## Dismiss, Sheets, and File Pickers

> PR: #1195 — popover dismissing when user clicks inside NSOpenPanel  
> See also: `AppDelegate.swift`, `AppDelegate+PanelSetup.swift`, `WindowGrabber.swift`

### The problem

RunBot uses an NSPopover as its main UI surface. Inside the popover, SwiftUI presents a
Settings flow via `.sheet`, and inside that sheet the user can open a folder picker
(NSOpenPanel) to select a path.

NSOpenPanel opens as a separate window. When the user clicks inside it, the click lands
outside the popover’s frame. RunBot’s global `NSEvent` monitor sees an outside click and
calls `hidePanel()`, dismissing both the popover and the sheet before the user has picked
anything. This is the bug fixed by PR #1195.

### Popover configuration

```
behavior  = .applicationDefined
animates  = false
delegate  = AppDelegate
```

**Why `.applicationDefined` and not `.transient`:**

`.transient` closes on any outside interaction with no awareness of NSOpenPanel. Worse: with
`.transient` AppKit bypasses the global NSEvent monitor entirely — it closes the popover
internally without ever delivering the click event to our handler. This made every guard and
flag in Attempts 4–7 unreachable dead code.

`.applicationDefined` keeps dismiss control in our hands. AppKit consults
`popoverShouldClose(_:)` before dismissing, and our global event monitor receives every
outside click so we can decide what to do with it.

**Re-asserting `behavior` and `delegate` before every `show()`:**

AppKit latches `behavior` at `popover.show()` time, not at assignment time. If the value ever
resets between sessions, the next open silently runs as `.transient`. Fix: re-assert
`popover.behavior = .applicationDefined` and `popover.delegate = self` immediately before
every `popover.show()` call in `openPanel()`.

### How the dismiss pipeline works

```
Status bar click
    └─> togglePanel()
            └─> openPanel()
                    ├─> popover.show()
                    ├─> install outsideClickMonitor  (NSEvent global monitor)
                    └─> install workspaceObserver    (NSWorkspace notification)

Outside click
    └─> outsideClickMonitor fires
            ├─> guard panelIsOpen
            ├─> guard !hasActiveSheet      ← THE KEY GUARD
            ├─> guard click not in popover frame
            └─> hidePanel()

App switch
    └─> workspaceObserver fires
            ├─> guard panelIsOpen
            ├─> guard !hasActiveSheet
            ├─> guard activatedApp != NSRunningApplication.current
            └─> hidePanel()

Any close path
    └─> tearDownOpenState()
            ├─> removes outsideClickMonitor
            └─> removes workspaceObserver
```

`popoverShouldClose(_:)` always returns `true`. AppKit is never blocked here. All dismiss
control goes through `outsideClickMonitor` and `workspaceObserver`.

### The fix — `hasActiveSheet` + `beginSheetModal`

**1. `beginSheetModal(for: popoverWindow)`**

NSOpenPanel is opened using `picker.beginSheetModal(for: hostWindow)` instead of
`picker.begin { }` or `picker.runModal()`. `beginSheetModal` attaches NSOpenPanel as a child
sheet of the popover’s own `NSWindow`, making it appear in `popoverWindow.sheets`.

`picker.begin { }` opens NSOpenPanel as a free-floating window that is completely invisible to
every guard mechanism: `NSApp.modalWindow` is `nil`, `NSApp.windows` doesn’t contain it,
`popoverWindow.sheets` doesn’t contain it. `beginSheetModal` fixes all three at once.

**2. `guard !hasActiveSheet`**

```swift
var hasActiveSheet: Bool {
    popover?.contentViewController?.view.window?.sheets.isEmpty == false
}
```

Both `outsideClickMonitor` and `workspaceObserver` guard on this before calling `hidePanel()`.
If any sheet is attached to the popover window — NSOpenPanel, SwiftUI `.sheet()`, or any
future modal — the monitor returns immediately. No dismiss.

**Why not a boolean flag (`isFilePickerActive`):**

Attempts 4–9 all tried a flag. Every one failed:

| Failure mode | Attempts affected |
|---|---|
| Flag set after `NSApp.activate()` fires the workspace notification (ordering race) | 6 |
| Flag read in non-isolated closure — Swift 6 stale-value warning | 6 |
| Flag threaded through `Task { @MainActor }` hop — new async timing window | 7 |
| Second call site (`AddRunnerSheet`) missed entirely — flag never set | 9 |

`hasActiveSheet` has none of these failure modes: it’s a direct structural check on
`popoverWindow.sheets` with no timing dependency and no call-site boilerplate.

### `WindowGrabber` — reliable `NSWindow` reference for `beginSheetModal`

`beginSheetModal(for:)` requires a valid `NSWindow` at call time. `NSApp.keyWindow` is
unreliable — key window can be `nil` or point to the wrong window depending on focus state.

`WindowGrabber` is a zero-size `NSViewRepresentable` that captures the hosting `NSWindow` via
`viewDidMoveToWindow()`, which fires when the SwiftUI view is first inserted into the view
hierarchy — before any user interaction is possible.

```swift
// In ScopeDetailView / AddRunnerSheet:
.background(WindowGrabber { w in
    if hostWindow == nil, let w { hostWindow = w }
})
```

**Gotcha:** `viewDidMoveToWindow()` also fires with `window = nil` when the view is removed.
The `if hostWindow == nil, let w` guard prevents it overwriting a valid reference. If a future
view can be re-attached to a different window, add `guard let window else { return }` inside
`WindowGrabber` itself and remove the call-site guard.

### Sheet state across hide/show

`hidePanel()` does **not** call `dismissSheets()` and does **not** reset `rootView`.
`popover.performClose()` closes `NSPopoverWindowFrame` and all child windows together —
removed from screen but the `NSHostingController` and its SwiftUI tree stay alive with
`@State` preserved. On re-open, `popover.show()` re-attaches the same controller and SwiftUI
re-presents the sheet automatically because the binding is still `true`.

`closePanel()` resets `rootView = mainView()` so the next open starts fresh.

### Rules

```
❌ NEVER use picker.begin { }            — free-floating, invisible to hasActiveSheet
❌ NEVER use picker.runModal()           — same reason
✅ ALWAYS use picker.beginSheetModal(for: hostWindow)

❌ NEVER call popover.show() on resize   — re-anchors the arrow; use contentSize only
❌ NEVER omit behavior re-assert before show() — AppKit latches at show-time
❌ NEVER omit delegate re-assert before show() — same reason

❌ NEVER add dismissSheets() to hidePanel()
❌ NEVER reset hostingController.rootView in hidePanel()

❌ NEVER remove tearDownOpenState() from any close path — monitor leak
❌ NEVER inline teardown back into AppDelegate.swift
❌ NEVER call popover.performClose() while a sheet is open without first calling
        hidePopoverWindowsPreservingSheets()
```
