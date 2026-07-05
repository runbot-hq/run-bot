# Definitive Guide: Preventing Side-Jumping in a macOS Status Bar Popover (NSPopover + SwiftUI)

> **Written for:** Any developer (human or AI) touching `AppDelegate.swift`, `PopoverView.swift`, or any sizing/frame/contentSize code in this project.  
> **Read this entire document before writing a single line.**

---

## The One Rule

**Call `popover.show(relativeTo:of:preferredEdge:)` exactly once per open.** Never call it again while the popover is visible.

Every side-jumping bug in this codebase's history has violated this rule.

---

## Why Jumping Happens

`NSPopover` has two completely independent concepts:

| Concept | API | What it controls |
|---|---|---|
| **Anchor** | `popover.show(relativeTo:of:preferredEdge:)` | Where the arrow attaches. Recalculated from scratch on every call. |
| **Size** | `popover.contentSize` | How big the popover body is. Pure resize around the fixed anchor. |

Every time you call `show()`, AppKit recomputes the anchor geometry from the current `button.bounds` and the *current* `contentSize`. If the size has changed since the last `show()`, the anchor lands in a slightly different horizontal position — that's the jump.

---

## The Fix

```swift
// AppDelegate.swift — openPanel()
// Called ONCE when the user clicks the status bar button.
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

// PopoverSizeObserver.swift — KVO callback
// Called whenever SwiftUI changes preferredContentSize.
// NEVER calls show() again.
popover.contentSize = NSSize(width: newWidth, height: newHeight)
```

That's it. `contentSize` resizes the body in-place. The arrow never moves.

---

## `animates = false` Is Not Optional

With `animates = true` (AppKit default), every `contentSize` write starts a 200 ms Core Animation resize. If SwiftUI fires multiple `preferredContentSize` KVO updates in one layout pass (it does), you get overlapping animations, stuttering, and apparent jumps.

```swift
popover.animates = false   // set this at init time, never change it
```

---

## What NOT to Do

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

Common mistakes that cause jumping:

| Mistake | Why it jumps |
|---|---|
| Calling `popover.show()` again on resize | `show()` re-runs full anchor calculation from scratch |
| `behavior = .transient` with size changes | Transient mode can close and re-show automatically in some AppKit paths |
| Setting `contentSize` before `show()` with wrong size | Popover opens at wrong size; `show()` is called again to "fix" it |
| `NSWindow.setFrame()` on the popover's window | Bypasses AppKit geometry; anchor recalculates on next event loop tick |

---

## History of This Bug in This Repo

| Commit / PR | What broke | Root cause |
|---|---|---|
| Pre-NSPopover migration | Jump on every resize | `NSPanel.setFrame()` couples position and size |
| First NSPopover attempt | Jump on tab switch | `show()` called in the resize observer |
| #1017 workaround attempt | Jump on sheet present | `show()` called to "reposition after promotion" |

All three: calling `show()` more than once per open.

---

## Checklist Before Merging Any PR That Touches Popover Code

- [ ] `popover.show()` is called in exactly one place (the status bar button action)
- [ ] No resize/layout observer calls `show()`
- [ ] `popover.animates` is `false`
- [ ] `contentSize` is the only API used for size changes while the popover is open
- [ ] Tested: open popover, trigger a size change (switch tab, load data), confirm no horizontal shift

---

*Related: `docs/ui/status-bar-window.md` (why NSPopover won over NSPanel), `docs/ui/nspopover-dismiss-and-sheets.md` (sheet orphan prevention).*
