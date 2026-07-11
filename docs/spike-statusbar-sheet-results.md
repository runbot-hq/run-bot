# StatusBar Sheet Spike Results

> Branch: `spike/statusbar-sheet-swiftui`  
> Run: `swift run StatusBarSheetSpike` on macOS 13+

This spike proves that a **pure SwiftUI** status-bar app (no `AppDelegate`,
no `NSStatusItem`, no `NSPopover`) can present and dismiss a `.sheet` without
hiding the status-bar item or terminating the app.

---

## How to Run

```bash
git checkout spike/statusbar-sheet-swiftui
swift run StatusBarSheetSpike
```

---

## Test Checklist

### Scenario A — Dismiss closes ONLY the sheet

- Action: Click status-bar icon → click "Open Sheet" → click "Dismiss Sheet"
- Expected: Sheet disappears
- Expected: MenuBarExtra **window stays open**
- Expected: Status-bar icon **stays in menu bar**
- Expected: App process does **NOT terminate**
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Scenario B — Window is not recreated on dismiss

- Action: Open window → open sheet → dismiss sheet → observe "Window open count"
- Expected: Counter stays at `1` across multiple sheet open/dismiss cycles
- Expected: Counter only increments when the window is **reopened** (icon click)
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- **If FAIL:** `ContentView.onAppear` fires more than once → SwiftUI is
  recreating the view on sheet dismiss → move critical state to an
  `@Observable` class owned by the `App` struct (same pattern as
  `SpikeAppState` in `RunBotSpike`).

### Scenario C — Status-bar icon survives multiple open/dismiss cycles

- Action: Open sheet → dismiss → open sheet → dismiss (repeat 5×)
- Expected: Icon remains in menu bar throughout
- Expected: Clicking icon always reopens the window
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Scenario D — Dismiss counter persists inside the sheet

- Action: Dismiss sheet (increments counter) → reopen sheet
- Expected: Counter retains its value across open/dismiss cycles
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- **If FAIL:** Sheet view is destroyed on dismiss → sheet-local `@State` is
  not preserved → lift `dismissCount` to `ContentView` state or to an
  `@Observable` app-level model.

---

## Decision Matrix

| Scenario | Pass | Architectural impact |
|---|---|---|
| A | ✅ | Pure SwiftUI `.sheet` + binding dismiss is safe. |
| A | ❌ | Use `NSPanel.beginSheet` / `WindowGrabber` pattern instead. |
| B | ✅ | View-local `@State` is preserved; no forced lift needed. |
| B | ❌ | Lift all persistent state to an `@Observable` class on `App`. |
| C | ✅ | `MenuBarExtra` lifecycle is stable; proceed with migration. |
| C | ❌ | File a follow-up issue; do not migrate from `NSPopover` yet. |
| D | ✅ | Sheet view is not destroyed on dismiss; sheet-local state is safe. |
| D | ❌ | Lift sheet state to parent. |

---

## Results Summary

> Fill in after running the spike.

- macOS version tested:
- Swift version tested:
- Date:
- Tester:

| Scenario | Result | Notes |
|---|---|---|
| A — Dismiss closes only sheet | | |
| B — Window not recreated | | |
| C — Icon survives cycles | | |
| D — Sheet counter persists | | |

**Overall verdict:**
- [ ] All pass → pure SwiftUI `.sheet` pattern is verified; proceed
- [ ] Any fail → see Decision Matrix above for remediation
