# Status Bar Sheet Spike — Results

> Branch: `spike/statusbar-sheet`  
> Run: `swift run StatusBarSheetSpike` on macOS 26  

## The Question

> Can a pure-SwiftUI (no `AppDelegate`) macOS status bar app present a
> `.sheet()` **inside the `MenuBarExtra` window itself**, and have a
> Dismiss button that closes only the sheet — leaving the `MenuBarExtra`
> window and the status-bar icon fully intact?

## Architecture

```
MenuBarExtra("🧪 Sheet Spike")  ← .window style
  └── SpikeContentView
        ├── counter (@State)
        ├── Button("Open Sheet") → isSheetPresented = true
        ├── .sheet(isPresented: $isSheetPresented)
        │     └── SheetView
        │           └── Button("Dismiss") → isPresented = false
        └── SheetDismissGuardView  ← zero-size NSViewRepresentable
              └── SheetDismissGuard  ← NSObject, observes willCloseNotification
                    └── on close while suppressed → orderFront (re-shows window)
```

## Why the naive approach fails

When `.sheet()` is dismissed inside a `MenuBarExtra` window, AppKit
interprets the focus loss as an outside-click and sends a close event to
the hosting `NSWindow`. Without a guard, the entire popover closes.

## The fix

`SheetDismissGuard` watches the `isSheetPresented` binding. When it
detects a `true → false` transition it sets `suppressNextHide = true`.
If `NSWindow.willCloseNotification` fires while suppressed, it calls
`orderFront` on the next run-loop tick to re-show the window and clears
the flag. This mirrors the `PopoverLifecycleCoordinator` pattern in the
main RunBot target.

---

## How to Run

```bash
git checkout spike/statusbar-sheet
swift run StatusBarSheetSpike
```

1. Click the **🧪 flask** icon in the menu bar.
2. Increment the counter.
3. Click **"Open Sheet"** — sheet slides up inside the same window.
4. Click **"Dismiss"**.
5. Verify: only the sheet closes; the MenuBarExtra window stays open; counter unchanged.
6. Click the 🧪 icon again — still works.

---

## Test Checklist

### Step 1 — Sheet opens inside MenuBarExtra window
- Action: Click "Open Sheet"
- Expected: Sheet slides up inside the MenuBarExtra window (not a separate window)
- Result: `[ ]` ✅ Pass / ❌ Fail

### Step 2 — Dismiss closes only the sheet
- Action: With sheet open, click "Dismiss"
- Expected: Sheet closes; MenuBarExtra window remains open
- Result: `[ ]` ✅ Pass / ❌ Fail

### Step 3 — Status bar icon survives dismiss
- Action: After Dismiss, click 🧪 icon again
- Expected: MenuBarExtra window opens normally
- Result: `[ ]` ✅ Pass / ❌ Fail

### Step 4 — Panel state survives sheet open/close
- Action: Increment counter → Open Sheet → Dismiss
- Expected: Counter value unchanged after dismiss
- Result: `[ ]` ✅ Pass / ❌ Fail

### Step 5 — Multiple cycles
- Action: Open Sheet → Dismiss (repeat 3×)
- Expected: Each cycle works; no crash; icon stays alive
- Result: `[ ]` ✅ Pass / ❌ Fail

---

## Results Summary

> Fill in after running.

- macOS version tested:
- Swift version tested:
- Date:
- Tester:

| Step | Result | Notes |
|---|---|---|
| 1 — Sheet inside MenuBarExtra | | |
| 2 — Dismiss closes only sheet | | |
| 3 — Icon survives | | |
| 4 — Panel state intact | | |
| 5 — Repeat cycles | | |

**Verdict:**
- [ ] All pass → `SheetDismissGuard` pattern confirmed; apply to RunBot migration (#1987)
- [ ] Any fail → record failure mode and file follow-up issue
