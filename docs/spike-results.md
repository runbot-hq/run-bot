# SwiftUI Lifecycle Spike Results

> Branch: `spike/swiftui-lifecycle`  
> Ref: issue #1987  
> Run: `swift run RunBotSpike` on macOS 26

This document records the results of the sheet-preservation and MenuBarExtra
behaviour spike. Results here determine whether the proposed `RunBotApp` +
`AppState` + `RootView` architecture is safe to proceed with.

For architectural context see:
- [decisions.md](decisions.md) — NSPopover decisions being replaced
- [architecture.md](architecture.md) — concurrency and data model

---

## How to Run

```bash
git checkout spike/swiftui-lifecycle
swift run RunBotSpike
```

For Scenario 9 (OAuth URL), in a separate terminal:
```bash
open "runbotspike://test"
```

---

## Test Checklist

For each scenario: open the spike app, perform the action, record ✅ Pass / ❌ Fail / ⚠️ Partial.

### Scenario 1 — View-local `@State` integer survives close/reopen
- Action: Increment counter → click outside to close → reopen menu bar icon
- Expected: Counter retains incremented value
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Scenario 2 — View-local `TextField` `@State` survives close/reopen
- Action: Type text → close → reopen
- Expected: Text is still present
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Scenario 3 — Sheet open state survives hide/show (outside-tap)
- Action: Open local sheet → click outside app to hide → reopen menu bar icon
- Expected: Sheet re-appears open automatically
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- **If FAIL:** Use Scenario 6 (app-level sheet state) as the pattern. Move `showSheet` to `AppState`.

### Scenario 4 — Navigate to Settings, increment counter, navigate back, return to Settings
- Action: Go to Settings → increment counter → Back → Go to Settings again
- Expected: Counter preserved within same session (NOT required across close/reopen)
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:

### Scenario 5 — `.task` lifecycle (console)
- Action: Watch console. Open app, close, reopen multiple times.
- Expected: `🔵 [Spike] .task started (count=1)` prints exactly ONCE
- Expected: `taskStartCount` in UI stays at `1`
- Result: `[ ]` ✅ Pass (prints once) / ❌ Fail (prints on every open)
- Notes:
- **If FAIL:** `.task` is scene-lifetime not app-lifetime. `AppState.start()` must be called differently — move to `init` of `AppState` and drive with `AsyncStream`.

### Scenario 6 — App-level sheet state (`@Observable` on `App` struct)
- Action: Open app-state sheet → close → reopen
- Expected: Sheet re-appears (state owned by `SpikeAppState`, not view)
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- This is the **fallback pattern** if Scenario 3 fails.

### Scenario 7 — `.fileImporter` does not dismiss the app
- Action: Open file picker → click anywhere inside the picker panel
- Expected: App (MenuBarExtra) does NOT dismiss
- Expected: No outside-click guard code needed
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- **If FAIL:** `WindowGrabber` + `beginSheetModal` pattern must be retained.

### Scenario 8 — Rounded corners survive sheet presentation
- Action: Open local sheet (Scenario 3) → inspect the MenuBarExtra window chrome
- Expected: Window retains rounded corners while sheet is presented
- Expected: No `CAShapeLayer` mask or `NSVisualEffectView` needed
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- **If FAIL:** `NSPopover` architecture must be retained (see decisions.md §Why NSPopover).

### Scenario 9 — `.onOpenURL` receives OAuth callback
- Action: Run `open "runbotspike://test"` in Terminal while app is running
- Expected: URL appears in the Scenario 9 readout box in the UI
- Expected: `🔵 [Spike] onOpenURL fired` in console
- Result: `[ ]` ✅ Pass / ❌ Fail
- Notes:
- **If FAIL:** `NSAppleEventManager` shim in `NSApplicationDelegateAdaptor` must be retained.

---

## Decision Matrix

After filling in results above:

| Scenario | Pass | Architectural impact |
|---|---|---|
| 1 + 2 | ✅ | View-local `@State` is safe. No forced lift to `AppState`. |
| 1 + 2 | ❌ | All persistent UI state must live on `AppState`. |
| 3 | ✅ | Sheet open state can stay view-local. |
| 3 | ❌ | `showSheet` flags move to `AppState`. Use Scenario 6 pattern. |
| 5 | ✅ | `AppState.start()` safe as `.task` on root view. |
| 5 | ❌ | Move `start()` to `AppState.init()`, drive poll loop internally. |
| 7 | ✅ | Delete `WindowGrabber.swift`. |
| 7 | ❌ | Retain `WindowGrabber` + `beginSheetModal` pattern. |
| 8 | ✅ | Delete `PanelChromeView` / `NSVisualEffectView` setup. |
| 8 | ❌ | `NSPopover` architecture must be retained. Do not proceed with migration. |
| 9 | ✅ | Delete `AppDelegate+OAuthCallback.swift`. |
| 9 | ❌ | Retain `NSApplicationDelegateAdaptor` shim for OAuth. |

---

## Results Summary

> Fill in after running the spike.

- macOS version tested:
- Swift version tested:
- Date:
- Tester:

| Scenario | Result | Notes |
|---|---|---|
| 1 — View-local counter | | |
| 2 — View-local TextField | | |
| 3 — Sheet open across hide | | |
| 4 — Nav state within session | | |
| 5 — `.task` start count | | |
| 6 — App-level sheet state | | |
| 7 — `.fileImporter` no dismiss | | |
| 8 — Rounded corners + sheet | | |
| 9 — `.onOpenURL` OAuth | | |

**Overall verdict:**
- [ ] All pass → proceed with full migration per issue #1987
- [ ] Partial → adapt architecture per Decision Matrix above, then proceed
- [ ] Scenario 8 fails → do NOT proceed; file follow-up issue
