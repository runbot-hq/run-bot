# Status Bar Sheet Spike — Results

> Branch: `spike/statusbar-sheet`  
> Run: `swift run StatusBarSheetSpike` on macOS 26  
> Related: question verified in research before this spike was written

This spike answers one focused question:

> **Can a pure-SwiftUI (no AppDelegate) macOS status bar app present a sheet  
> whose Dismiss button closes only the sheet — leaving the status bar icon  
> and the MenuBarExtra window fully intact?**

---

## Architecture Used

```
App body
├── MenuBarExtra("🧪 Sheet Spike")   ← thin trigger only, no .sheet() here
│   └── MenuBarTriggerView
│       └── Button("Open Panel") → openWindow(id: "sheet-spike-panel")
│
└── Window(id: "sheet-spike-panel")  ← hosts ALL real UI
    └── PanelView
        ├── counter (view-local @State)
        ├── Button("Open Sheet") → isSheetPresented = true
        └── .sheet(isPresented: $isSheetPresented)
            └── SheetView
                └── Button("Dismiss") → isPresented = false
```

**Why this works:**  
The `.sheet()` is attached to a view inside a `Window` scene, not inside the
`MenuBarExtra` content closure. SwiftUI's sheet lifecycle operates on the
`Window` scene's hosting window. Setting `isPresented = false` only collapses
the sheet overlay — the `Window` scene's `NSWindow` is unaffected, and the
`MenuBarExtra` status item has no connection to either.

**Why the naive approach fails:**  
Attaching `.sheet()` directly to content inside `MenuBarExtra` causes the
popover's key-window / focus machinery to interpret any interaction inside the
sheet as an outside-click, which dismisses the popover window. This is a known
SwiftUI + AppKit integration issue (not a bug in the sheet itself).

---

## How to Run

```bash
git checkout spike/statusbar-sheet
swift run StatusBarSheetSpike
```

Then follow the steps printed in the source file header, or:

1. Click the **🧪 flask** icon in the menu bar.
2. Click **"Open Panel"** → a window opens.
3. Inside the panel, click **"Open Sheet"** → sheet slides up.
4. Click **"Dismiss"** inside the sheet.
5. Verify: only the sheet closes. The panel window stays open. The 🧪 icon stays in the menu bar.
6. Click the 🧪 icon again — it opens the trigger menu normally.

---

## Test Checklist

### Step 1 — Basic sheet open / dismiss
- Action: Open Panel → Open Sheet → Dismiss
- Expected: Sheet closes; Panel window remains open; 🧪 icon stays in menu bar
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Step 2 — Status bar icon survives dismiss
- Action: After Dismiss, click 🧪 icon again
- Expected: MenuBarExtra trigger menu opens normally
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Step 3 — Panel state survives sheet open/close
- Action: Increment counter → Open Sheet → Dismiss
- Expected: Counter value unchanged after dismiss
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Step 4 — Multiple open/dismiss cycles
- Action: Open Sheet → Dismiss → Open Sheet → Dismiss (repeat 3×)
- Expected: Each cycle works identically; no crash; icon stays alive
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

---

## Results Summary

> Fill in after running.

- macOS version tested:
- Swift version tested:
- Date:
- Tester:

| Step | Result | Notes |
|---|---|---|
| 1 — Sheet dismiss | | |
| 2 — Icon survives | | |
| 3 — Panel state intact | | |
| 4 — Repeat cycles | | |

**Verdict:**
- [ ] All pass → pattern is confirmed; use `Window` + `openWindow` for all sheet presentations in RunBot migration
- [ ] Any fail → record failure mode; check macOS version; file follow-up issue
