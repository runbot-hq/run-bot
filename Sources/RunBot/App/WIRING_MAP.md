# PR-A Wiring Map — Popover / Sheet / Picker Layer

Step 1 output. No code changed. Reference for Steps 2–7.

---

## Files in scope

| File | Size | Role |
|---|---|---|
| `AppDelegate.swift` | ~25 KB | Property bag + open/hide/close/toggle/resize logic |
| `AppDelegate+PanelSetup.swift` | ~17 KB | `setupPanel()`, `setupKVO()`, `setupSubscriptions()`, `openPanel()` monitors |
| `AppDelegate+StatusItem.swift` | ~3.5 KB | `NSStatusItem` creation and status icon observation task |
| `PopoverLifecycleCoordinator.swift` | ~19 KB | Outside-click monitor, workspace observer, `isSheetDismissing`, `panelIsOpen`, `preservedSheetWindowHide` |
| `WindowGrabber.swift` | ~2.2 KB | Resolves the popover-backing `NSWindow` for `NSOpenPanel` attachment |

---

## Properties on AppDelegate that touch the popover/sheet/picker layer

| Property | Type | Owner after PR-A |
|---|---|---|
| `statusItem` | `NSStatusItem?` | **Deleted** — `MBKPopoverController` owns it |
| `popover` | `NSPopover?` | **Deleted** — `MBKPopoverController` owns it |
| `hostingController` | `NSHostingController<AnyView>?` | **Deleted** — `MBKPopoverController` owns it |
| `lifecycleCoordinator` | `PopoverLifecycleCoordinator` | **Deleted** — replaced by `MBKOverlayGate` + `MBKPopoverController` internals |
| `sizeObservation` | `NSKeyValueObservation?` | **Deleted** — MBK uses `sizingOptions = .preferredContentSize` |
| `panelIsOpen` | `Bool` (computed, forwarded from coordinator) | **Deleted** — `MBKPopoverController` owns open state internally |
| `preservedSheetWindowHide` | `Bool` (computed, forwarded from coordinator) | **Deleted** — hide-and-restore path not needed with MBK (see `STAY-OPEN-WHILE-SHEET-ACTIVE` in `PopoverController.swift`) |
| `hasActiveSheet` | `Bool` (computed) | **Deleted** — `MBKOverlayGate.hasActiveOverlay` replaces this |
| `panelVisibilityState` | `PanelVisibilityState` | **Stays** — needed by `PanelContainerView` dim overlay; keep in `wrapEnv` |
| `panelSheetState` | `PanelSheetState` | **Stays** — transient hide state; assess during Step 4 |
| `popoverController` | `MBKPopoverController` | **New** — created in `applicationDidFinishLaunching` |
| `overlayGate` | `MBKOverlayGate` | **New** — created in `applicationDidFinishLaunching`, injected via `@Environment` |

---

## Call sites — `setupPanel()`

| Location | Call | Notes |
|---|---|---|
| `AppDelegate+PanelSetup.swift` | defines `setupPanel()` | Contains `setupStatusItem()`, `setupPopover()`, `setupKVO()`, `setupSubscriptions()` |
| `applicationDidFinishLaunching` (in `AppDelegate+PanelSetup.swift`) | `setupPanel()` | **Replaced** by `popoverController.setup()` + explicit `setupSubscriptions()` call |

---

## Call sites — `openPanel()`

| Location | Notes |
|---|---|
| `togglePanel()` in `AppDelegate.swift` | Called when panel is closed |
| `AppDelegate+Navigation.swift` | Called after auth callback to re-open the panel |

`openPanel()` itself calls:
- `lifecycleCoordinator.setPanelIsOpen(true)` → replaced by MBKPopoverController internal state
- `restorePopoverWindowsPreservingSheetsIfNeeded()` → **deleted** (hide-and-restore not needed)
- `popover.show(...)` → replaced by `MBKPopoverController.togglePopover()` / internal `openPopover()`
- `makePopoverWindowKeyIfPossible()` → **deleted** (MBKPopoverController calls `NSApp.activate`)
- `resizeAndRepositionPanel()` → **deleted** (MBK uses `sizingOptions = .preferredContentSize`)
- `navigate(to: restored)` for saved nav state → **stays**, wired via new `popoverController` open callback if needed
- `panelSheetState.restoreTransientHideStateIfNeeded()` → assess in Step 4
- `lifecycleCoordinator.installMonitors(...)` → **deleted** (MBKPopoverController installs its own monitors)

---

## Call sites — `hidePanel()`

| Location | Notes |
|---|---|
| `lifecycleCoordinator` outside-click monitor closure | Fires on click outside popover |
| `lifecycleCoordinator` workspace observer closure | Fires on app-switch |
| `togglePanel()` in `AppDelegate.swift` | Called when panel is open (closes it) |

`hidePanel()` itself calls:
- `panelSheetState.captureTransientHideState()` → assess in Step 4
- `hidePopoverWindowsPreservingSheets()` → **deleted**
- `popover?.performClose(nil)` → replaced by MBKPopoverController internal `performClose`
- `tearDownOpenState()` → **deleted** (MBK teardown is internal)

---

## Call sites — `closePanel()`

| Location | Notes |
|---|---|
| `togglePanel()` in `AppDelegate.swift` | When panel is open and user taps icon |
| `AppDelegate+Navigation.swift` | On explicit back/nav close |
| Various view callbacks | Via `onClose` closure injected into views |

`closePanel()` calls:
- `popover?.performClose(nil)` → replaced by MBKPopoverController
- `lifecycleCoordinator.setPreservedSheetWindowHide(false)` → **deleted**
- `tearDownOpenState()` → **deleted**
- `hostingController?.rootView = mainView()` → needs reassessment in Step 2 (MBK owns the hosting controller)

---

## Call sites — `togglePanel()`

| Location | Notes |
|---|---|
| `NSStatusItem` button action (set in `AppDelegate+StatusItem.swift`) | **Deleted** — MBKPopoverController wires its own `@objc togglePopover` as the button action |

---

## Call sites — `installMonitors()`

| Location | Notes |
|---|---|
| `openPanel()` in `AppDelegate.swift` | Installs after `popover.show()` |

**Deleted** — `MBKPopoverController.setupWorkspaceObserver()` and `startEventMonitor()` replace this entirely.

---

## `setupSubscriptions()` — current location and call site

`setupSubscriptions()` is defined inside `AppDelegate+PanelSetup.swift` as part of the `PanelSetup` extension. It is called from `setupPanel()`. After `setupPanel()` is replaced by `popoverController.setup()` in Step 2, `setupSubscriptions()` needs an **explicit call site** in `applicationDidFinishLaunching`.

`setupSubscriptions()` wires:
- `RunnerPoller` init (assigns `self.runnerStore`)
- `LocalRunnerStore.configure(viewModel: runnerState)`
- `localRunnerStore.refreshAsync()`
- Auto-updater startup
- Sign-out subscription

---

## `.sheet()` call sites that need outside-click survival → `.mbkSheet()`

To be enumerated in Step 4 by searching for `.sheet(item:` and `.sheet(isPresented:` in `Sources/RunBot/Views/`.

---

## `WindowGrabber` scope

`WindowGrabber.swift` (~2.2 KB) resolves the popover-backing `NSWindow` via
`NSApp.windows` predicate so `NSOpenPanel` can be attached as a sheet child.
No hit-testing, no z-order manipulation. Safe to delete once `mbkOpenFilePicker()` is wired.
Call sites to enumerate in Step 5.

---

## `suppressHidePanel()` call site

Currently **no call site** (`periphery:ignore` annotated). Belongs in `LocalRunnersView`
on both onCancel and onCommit paths, immediately before `editingRunner = nil`.
Must be synchronous — no `await` between the call and the binding mutation.
To be wired in Step 4.

---

## What MBKPopoverController replaces (summary)

| Old | New |
|---|---|
| `NSStatusItem` setup in `AppDelegate+StatusItem.swift` | `MBKPopoverController` internal `setupStatusItem()` |
| `NSPopover` setup in `AppDelegate+PanelSetup.swift` | `MBKPopoverController` internal `setupPopover()` |
| KVO on `preferredContentSize` (`sizeObservation`) | `hostingController.sizingOptions = .preferredContentSize` |
| `NSEvent` outside-click monitor in `PopoverLifecycleCoordinator` | `MBKPopoverController.startEventMonitor()` |
| `NSWorkspace` app-switch observer in `PopoverLifecycleCoordinator` | `MBKPopoverController.setupWorkspaceObserver()` |
| `isSheetDismissing` flag | `MBKOverlayGate.hasActiveOverlay` |
| `hidePopoverWindowsPreservingSheets()` / `restoreTransientHideStateIfNeeded()` | **Deleted** — MBK stays open while overlay active (see `STAY-OPEN-WHILE-SHEET-ACTIVE`) |
| `popoverShouldClose` always-true + monitor-side guard | `popoverShouldClose` returns `!overlayGate.hasActiveOverlay` |
