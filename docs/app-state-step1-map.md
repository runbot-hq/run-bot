# Step 1 — AppDelegate property bag map

> Issue #2040 · branch `feat/app-state-consolidation`

Complete inventory of every stored property and extension across the 9 files in
`Sources/RunBot/App/`. Each property is tagged with its intended destination once
`AppState` exists.

**Destination key**
- `→ AppState` — moves into `AppState` as an owned sub-object or property
- `→ AppDelegate (wiring)` — stays on `AppDelegate`; it is UI / lifecycle plumbing
- `→ AppDelegate (permanent)` — never moves; tightly coupled to `NSApplicationDelegate` or `@objc`
- `→ decide` — ownership needs an explicit decision before Step 2 proceeds

---

## `AppDelegate.swift` (26 KB)

### Stored properties

| Property | Type | Destination | Notes |
|---|---|---|---|
| `statusItem` | `NSStatusItem?` | → AppDelegate (permanent) | Owned by status-bar lifecycle |
| `popover` | `NSPopover?` | → AppDelegate (permanent) | NSPopover wiring |
| `hostingController` | `NSHostingController<AnyView>?` | → AppDelegate (permanent) | SwiftUI host, never recreated |
| `overlayGate` | `MBKOverlayGate` | → AppDelegate (wiring) | MenuBarKit; injecting into AppState would be a layering violation |
| `github` | `GitHubClient` | → AppState | Domain dependency; injected into views via AppState |
| `lifecycleService` | `any RunnerLifecycleServiceProtocol` | → AppState | Domain service |
| `localRunnerStore` | `LocalRunnerStore` (lazy) | → AppState | Domain store; lazy because configure() must run first |
| `runnerStore` | `(any RunnerPollerProtocol)?` | → AppState | Domain poll actor; nil until setupSubscriptions |
| `runnerState` | `RunnerState` | → AppState | Observable read model for all runner/job/action state |
| `autoUpdater` | `AppUpdater` | → AppState | Update driver; injected into SettingsView |
| `savedNavState` | `NavState?` | → AppState | Persists nav destination across popover hide/show |
| `panelSheetState` | `PanelSheetState` | → decide | Survives transient hides; unclear if domain or wiring |
| `statusIconTask` | `Task<Void, Never>?` | → decide | Retained task handle; lifetime = app lifetime |
| `signOutTask` | `Task<Void, Never>?` | → decide | Retained task handle for sign-out stream |
| `lifecycleCoordinator` | `PopoverLifecycleCoordinator` | → AppDelegate (permanent) | Owns panelIsOpen, monitors, NSEvent wiring |
| `sizeObservation` | `NSKeyValueObservation?` | → AppDelegate (permanent) | KVO token for preferredContentSize |
| `panelVisibilityState` | `PanelVisibilityState` | → AppDelegate (wiring) | SwiftUI observable injected via wrapEnv; regression guard in architecture.md |

### Computed properties

| Property | Destination | Notes |
|---|---|---|
| `oauthService` | → AppState | Forwarded from `github.oauthService`; can become a simple computed var on AppState |
| `panelIsOpen` | → AppDelegate (permanent) | Forwarded from lifecycleCoordinator |
| `preservedSheetWindowHide` | → AppDelegate (permanent) | Forwarded from lifecycleCoordinator |
| `maxWidth` | → AppDelegate (permanent) | Screen-geometry calc |
| `maxHeight` | → AppDelegate (permanent) | Screen-geometry calc |
| `statusItemScreen` | → AppDelegate (permanent) | Screen-geometry calc |
| `hasActiveSheet` | → AppDelegate (permanent) | Reads popoverWindow.sheets |

### Methods that move with domain state

`wrapEnv(_:)` — stays on AppDelegate but slims down. After #2040:
```swift
// Current (4 injections):
.environment(panelVisibilityState)
.environment(runnerState)          // → becomes .environment(appState)
.environment(overlayGate)
.environment(\.suppressHidePanel, suppressHidePanel)

// Post-#2040 (still 4 injections, but runnerState access goes via appState):
.environment(appState)
.environment(overlayGate)
.environment(panelVisibilityState)
.environment(\.suppressHidePanel, suppressHidePanel)
```

`wrapEnv` is **not deleted**. `overlayGate` and `panelVisibilityState` cannot move
into `AppState` without introducing layering violations (MenuBarKit / ObservableObject
regression guard). See issue #2040 comment for rationale.

---

## `AppDelegate+Navigation.swift` (5 KB)

Owns all view factories and nav callbacks. No stored properties.

| Method | Destination | Notes |
|---|---|---|
| `mainView()` | → AppDelegate (permanent) | Builds root SwiftUI tree; calls `wrapEnv` |
| `settingsView()` | → AppDelegate (permanent) | Calls `wrapEnv`; PanelContainerView applied here |
| `navigateToSettings()` | → AppDelegate (permanent) | Writes `savedNavState`; will write via appState post-#2040 |
| `validatedView(for:)` | → AppDelegate (permanent) | Reads `runnerState.jobs`; will read via `appState.runnerState` |

All reads of `runnerState`, `savedNavState`, `panelSheetState`, `oauthService`,
`lifecycleService`, `autoUpdater` in this file switch to `appState.x` in Step 4.

---

## `AppDelegate+OAuthCallback.swift` (841 B)

Single method: `application(_:open:)`. Calls `oauthService.handleCallback(url)`.
After Step 4 becomes `appState.oauthService.handleCallback(url)`. No stored properties.

---

## `AppDelegate+PanelSetup.swift` (17 KB)

Owns `NSPopoverDelegate` conformance, KVO, and the full async startup sequence.
No stored properties — all writes go to properties defined in `AppDelegate.swift`.

| Method | Destination | Notes |
|---|---|---|
| `setupPanel()` | → AppDelegate (permanent) | NSPopover + NSHostingController construction |
| `popoverShouldClose(_:)` | → AppDelegate (permanent) | NSPopoverDelegate; always returns true |
| `popoverDidClose(_:)` | → AppDelegate (permanent) | NSPopoverDelegate safety net |
| `setupKVO(controller:)` | → AppDelegate (permanent) | Wires preferredContentSize KVO |
| `setupSubscriptions()` | → AppState (Step 3) | Creates RunnerPoller, calls LocalRunnerStore.configure, spawns startup Task |
| `performStartupSequence()` | → AppState (Step 3) | refreshAsync → store.start → checkAndHandle → scheduleBackgroundCheck |

After Steps 3–5, `setupSubscriptions` and `performStartupSequence` move into
`AppState`. Only the four `NSPopoverDelegate`/KVO methods remain here. At that
point this file may be small enough to inline into `AppDelegate.swift` or kept
as a slim extension — do **not** delete until its contents are assessed.

---

## `AppDelegate+Polling.swift` (3 KB)

Owns `setupSignOutSubscription()`. Reads `oauthService` and `runnerStore`.
After Step 3 these become `appState.oauthService` and `appState.runnerStore`.
The method itself stays on AppDelegate (it writes to `signOutTask`) unless
task ownership moves to AppState in the Step 2 decision.

---

## `AppDelegate+StatusItem.swift` (3.5 KB)

Owns NSStatusItem creation and icon updates. All permanent AppDelegate wiring.

| Method | Destination | Notes |
|---|---|---|
| `setupStatusItem()` | → AppDelegate (permanent) | Creates NSStatusItem |
| `updateStatusIcon()` | → AppDelegate (permanent) | Reads `runnerState.runners`; becomes `appState.runnerState.runners` |
| `menuBarImage(for:)` | → AppDelegate (permanent) | Pure image helper |

---

## `AppDelegate+StoreSetup.swift` (5.6 KB)

Owns `applicationWillFinishLaunching` and `applicationDidFinishLaunching`.

The launch sequence after #2040:
1. `LocalRunnerStore.configure(viewModel: appState.runnerState)` — unchanged call, different receiver
2. `await ScopeStore.shared.refreshDisplayNames()` — unchanged
3. `setupStatusItem()` / `setupPanel()` / `setupSignOutSubscription()` — unchanged call sites; implementations read via `appState`
4. `statusIconTask` — ownership decision needed (→ decide); if it moves to AppState, this file calls `appState.startStatusIconObservation()`

---

## `EnvironmentValues+RunBot.swift` (1.4 KB)

Defines `SuppressHidePanelKey` and the `suppressHidePanel` environment value extension.
Pure SwiftUI environment plumbing. No stored properties. **Untouched by #2040.**

---

## `PopoverLifecycleCoordinator.swift` (22 KB)

Owns `panelIsOpen`, `isSheetDismissing`, `preservedSheetWindowHide`, the global
`NSEvent` outside-click monitor, and the `NSWorkspace` app-switch observer.
Extracted from `AppDelegate` in PR-A (#2039). **Entirely AppDelegate (permanent) —
untouched by #2040.**

---

## Open ownership decisions (Step 2 pre-requisites)

These three properties have no clear destination yet. They must be decided before
Step 2 begins:

1. **`panelSheetState: PanelSheetState`** — survives transient popover hides;
   `clearRunnerSheet()` is called from `closePanel()` and `settingsView.onBack`.
   Question: is this domain state (→ AppState) or popover wiring (→ AppDelegate)?

2. **`statusIconTask: Task<Void, Never>?`** — retained handle for the
   `Observations({ runnerState.aggregateStatus })` loop. Lifetime = app lifetime.
   Question: does AppState own its own observation tasks, or does AppDelegate
   retain all `Task` handles?

3. **`signOutTask: Task<Void, Never>?`** — retained handle for the sign-out
   stream loop in `setupSignOutSubscription()`. Same question as above.
