# PR-A Wiring Map — Popover / Sheet / Picker Layer

Step 1 output. No code changed. Reference for Steps 2–6.

> **Architectural boundary (corrected Jul 12):** RunBot retains full ownership of its `NSStatusItem`, dynamic icon observation task, and button action. `AppDelegate+StatusItem.swift` is NOT deleted in PR-A. `MBKPopoverController` is NOT adopted in PR-A — it assumes status-item ownership that conflicts with RunBot's app-specific dynamic icon logic. PR-A integrates only `MBKOverlayGate`, `.mbkSheet(overlayGate:)`, and `mbkOpenFilePicker()`. `PopoverLifecycleCoordinator` is reassessed after the sheet/picker integration is validated, not preemptively removed.

---

## Files in scope

| File | Size | Role |
|---|---|---|
| `AppDelegate.swift` | ~25 KB | Property bag + open/hide/close/toggle/resize logic |
| `AppDelegate+PanelSetup.swift` | ~17 KB | `setupPanel()`, `setupKVO()`, `setupSubscriptions()`, `openPanel()` monitors |
| `AppDelegate+StatusItem.swift` | ~3.5 KB | `NSStatusItem` creation and status icon observation task — **STAYS; app-owned** |
| `PopoverLifecycleCoordinator.swift` | ~19 KB | Outside-click monitor, workspace observer, `isSheetDismissing`, `panelIsOpen`, `preservedSheetWindowHide` |
| `WindowGrabber.swift` | ~2.2 KB | Resolves the popover-backing `NSWindow` for `NSOpenPanel` attachment |

---

## Properties on AppDelegate that touch the popover/sheet/picker layer

| Property | Type | Owner after PR-A |
|---|---|---|
| `statusItem` | `NSStatusItem?` | **STAYS — app-owned.** RunBot owns `NSStatusItem`, the dynamic icon observation task, and the button action. `MBKPopoverController` is NOT adopted in PR-A. |
| `popover` | `NSPopover?` | **Stays** — RunBot continues to own `NSPopover` in PR-A. |
| `hostingController` | `NSHostingController<AnyView>?` | **Stays** — RunBot continues to own the hosting controller in PR-A. |
| `lifecycleCoordinator` | `PopoverLifecycleCoordinator` | **RETAINED in PR-A** — see Step 5 assessment below. Not deleted. Remainder documented for PR-B/PR-C. |
| `sizeObservation` | `NSKeyValueObservation?` | **Stays** — KVO on `preferredContentSize` remains (MBK's `sizingOptions` path requires `MBKPopoverController` ownership, which is deferred). |
| `panelIsOpen` | `Bool` (computed, forwarded from coordinator) | **Stays** in PR-A. |
| `preservedSheetWindowHide` | `Bool` (computed, forwarded from coordinator) | **Stays** in PR-A — hide-and-restore path remains; coordinator not deleted. |
| `hasActiveSheet` | `Bool` (computed) | **Stays** — reads `popoverWindow.sheets`. Now supplemented by `overlayGate.hasActiveOverlay` in the `installMonitors` closure, but the structural window-sheets check remains authoritative for the native SwiftUI sheet path. |
| `panelVisibilityState` | `PanelVisibilityState` | **Stays** — needed by `PanelContainerView` dim overlay; keep in `wrapEnv`. |
| `panelSheetState` | `PanelSheetState` | **Stays** — transient hide state; assessed in Step 3. |
| `overlayGate` | `MBKOverlayGate` | **New (Step 2)** — created in `applicationDidFinishLaunching`, injected via `.environment(overlayGate)`. |

---

## Call sites — `setupPanel()`

| Location | Call | Notes |
|---|---|---|
| `AppDelegate+PanelSetup.swift` | defines `setupPanel()` | Contains `setupStatusItem()`, `setupPopover()`, `setupKVO()`, `setupSubscriptions()` |
| `applicationDidFinishLaunching` (in `AppDelegate+PanelSetup.swift`) | `setupPanel()` | **Stays in PR-A** — `MBKPopoverController.setup()` is not used. |

---

## Call sites — `openPanel()`

| Location | Notes |
|---|---|
| `togglePanel()` in `AppDelegate.swift` | Called when panel is closed |
| `AppDelegate+Navigation.swift` | Called after auth callback to re-open the panel |

`openPanel()` itself calls (all stay in PR-A):
- `lifecycleCoordinator.setPanelIsOpen(true)`
- `restorePopoverWindowsPreservingSheetsIfNeeded()`
- `popover.show(...)`
- `makePopoverWindowKeyIfPossible()`
- `resizeAndRepositionPanel()`
- `navigate(to: restored)` for saved nav state
- `panelSheetState.restoreTransientHideStateIfNeeded()`
- `lifecycleCoordinator.installMonitors(...)`

---

## Call sites — `hidePanel()`

| Location | Notes |
|---|---|
| `lifecycleCoordinator` outside-click monitor closure | Fires on click outside popover |
| `lifecycleCoordinator` workspace observer closure | Fires on app-switch |
| `togglePanel()` in `AppDelegate.swift` | Called when panel is open (closes it) |

`hidePanel()` itself calls (all stay in PR-A):
- `panelSheetState.captureTransientHideState()`
- `hidePopoverWindowsPreservingSheets()`
- `popover?.performClose(nil)`
- `tearDownOpenState()`

---

## Call sites — `closePanel()`

| Location | Notes |
|---|---|
| `togglePanel()` in `AppDelegate.swift` | When panel is open and user taps icon |
| `AppDelegate+Navigation.swift` | On explicit back/nav close |
| Various view callbacks | Via `onClose` closure injected into views |

`closePanel()` calls (all stay in PR-A):
- `popover?.performClose(nil)`
- `lifecycleCoordinator.setPreservedSheetWindowHide(false)`
- `tearDownOpenState()`
- `hostingController?.rootView = mainView()`

---

## Call sites — `togglePanel()`

| Location | Notes |
|---|---|
| `NSStatusItem` button action (set in `AppDelegate+StatusItem.swift`) | **Stays** — RunBot wires its own `togglePanel` as the button action. |

---

## Call sites — `installMonitors()`

| Location | Notes |
|---|---|
| `openPanel()` in `AppDelegate.swift` | Installs after `popover.show()` |

**Stays in PR-A** — coordinator monitors remain. `hasActiveSheet` closure now ORs in `overlayGate.hasActiveOverlay`.

---

## `setupSubscriptions()` — current location and call site

`setupSubscriptions()` is defined inside `AppDelegate+PanelSetup.swift` as part of the `PanelSetup` extension. It is called from `setupPanel()`. Stays as-is in PR-A.

`setupSubscriptions()` wires:
- `RunnerPoller` init (assigns `self.runnerStore`)
- `LocalRunnerStore.configure(viewModel: runnerState)`
- `localRunnerStore.refreshAsync()`
- Auto-updater startup
- Sign-out subscription

---

## `.sheet()` call sites that need outside-click survival → `.mbkSheet()`

To be enumerated in Step 3 by searching for `.sheet(item:` and `.sheet(isPresented:` in `Sources/RunBot/Views/`.

---

## `WindowGrabber` scope

`WindowGrabber.swift` (~2.2 KB) resolves the popover-backing `NSWindow` via
`NSApp.windows` predicate so `NSOpenPanel` can be attached as a sheet child.
No hit-testing, no z-order manipulation. Safe to delete once `mbkOpenFilePicker()` is wired.
Call sites to enumerate in Step 4.

---

## `suppressHidePanel()` call site

Currently **no call site** (`periphery:ignore` annotated). Belongs in `LocalRunnersView`
on both onCancel and onCommit paths, immediately before `editingRunner = nil`.
Must be synchronous — no `await` between the call and the binding mutation.
To be wired in Step 3.

---

## What PR-A actually changes (corrected scope)

| Old | New | Step |
|---|---|---|
| No `MBKOverlayGate` | `overlayGate: MBKOverlayGate` on `AppDelegate`, injected via `.environment()` | Step 2 |
| Outside-click-sensitive `.sheet()` calls | `.mbkSheet(overlayGate:)` | Step 3 |
| `suppressHidePanel()` has no call site | Wired in `LocalRunnersView` onCancel + onCommit, synchronous | Step 3 |
| `WindowGrabber` / `NSOpenPanel` | `mbkOpenFilePicker()` | Step 4 |
| `PopoverLifecycleCoordinator` / `isSheetDismissing` | **RETAINED** — not deleted. `MBKOverlayGate` supplements but does not replace it. Remainder documented for PR-B/PR-C. | Step 5 |
| `AppDelegate+StatusItem.swift` | **Unchanged — app-owned** | — |
| `MBKPopoverController` | **Not adopted in PR-A — deferred** | — |

---

## What MBKPopoverController does (deferred to future PR)

`MBKPopoverController` assumes full ownership of `NSStatusItem`, `NSPopover`, and `NSHostingController`. It installs its own button action (`@objc togglePopover`) and its own workspace/event monitors. Adopting it in RunBot requires removing RunBot's dynamic icon observation task from `AppDelegate+StatusItem.swift` and porting that logic into MBK or a separate coordinator. This is a non-trivial architectural change and is deferred to a future spike or PR-C.

---

## Step 5 — PopoverLifecycleCoordinator assessment (Jul 12 2026)

### Decision: RETAIN — not deleted in PR-A

`MBKOverlayGate.hasActiveOverlay` is now wired into the `hasActiveSheet` closure inside
`openPanel()` (as of Step 2). That means the outside-click monitor and workspace observer
already block dismiss when a file picker or MBK-managed sheet is active.

However, `MBKOverlayGate` is a **gate only** — a single boolean observable. It does not
replace the coordinator's monitors, panel-open flag, hide-and-restore machinery, or
sheet-dismiss suppression window. Deleting `PopoverLifecycleCoordinator` would require
adopting `MBKPopoverController`, which is explicitly deferred to PR-C.

### What `MBKOverlayGate` now owns (after PR-A)

| Concern | Owner |
|---|---|
| Tracks whether a MBK-managed sheet is currently presented | `MBKOverlayGate.hasActiveOverlay` (set by `MBKAnchoredSheet`) |
| Tracks whether the file picker is currently open | `MBKOverlayGate.hasActiveOverlay` (set/cleared by `mbkOpenFilePicker`) |
| Arms dismiss gate during picker lifetime | `MBKOverlayGate.hasActiveOverlay` |

### What `PopoverLifecycleCoordinator` still owns (not superseded)

| Concern | Why it cannot be deleted |
|---|---|
| `outsideClickMonitor` — global `NSEvent` monitor | MBK has no equivalent without `MBKPopoverController`. The gate is *read* by this monitor; it does not replace it. |
| `workspaceObserver` — `NSWorkspace.didActivateApplicationNotification` | Same — MBK does not install a workspace observer unless `MBKPopoverController` is adopted. |
| `panelIsOpen` flag | Guards both monitors. `MBKPopoverController.isShown` would replace this in PR-C. |
| `preservedSheetWindowHide` + `hidePopoverWindowsPreservingSheets()` | RunBot-specific hide-without-closing path. Replaces itself only when `MBKPopoverController` owns `NSPopover`. |
| `isSheetDismissing` + `suppressHidePanel()` | One-runloop-turn suppression during intentional sheet dismiss. Still wired alongside `overlayGate.hasActiveOverlay` in the `hasActiveSheet` closure. `MBKOverlayGate` does not replicate this timing window. |
| `tearDown()` | Removes both monitors + resets all flags on every close path. |

### `hasActiveSheet` closure after PR-A (in `openPanel()`)

```swift
hasActiveSheet: { [weak self] in
    guard let self else { return false }
    return self.hasActiveSheet                          // structural: popoverWindow.sheets non-empty
        || self.lifecycleCoordinator.isSheetDismissing  // one-runloop suppression window
        || self.overlayGate.hasActiveOverlay            // MBK gate: sheet or picker active (NEW PR-A)
},
```

All three arms are necessary. `overlayGate.hasActiveOverlay` is the only PR-A addition;
the other two arms are unchanged from before this PR.

### Remainder for PR-B / PR-C

| Concern | Target PR |
|---|---|
| Move `MBKOverlayGate` from `AppDelegate` → `AppState` | PR-B (#2040) |
| Adopt `MBKPopoverController` (replaces coordinator's monitors + `panelIsOpen` + `preservedSheetWindowHide`) | PR-C (future spike) |
| Delete `PopoverLifecycleCoordinator` once `MBKPopoverController` is adopted | PR-C |
| Confirm `suppressHidePanel()` / `isSheetDismissing` is replicated or superseded by MBK's sheet-dismiss path | PR-C assessment |
