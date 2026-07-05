# RunBot — UI Architecture Decisions

Regression guards and architectural decisions enforced inline in the source.
**Do not remove** the corresponding inline annotations without updating this file.

For deep-dives on specific subsystems see:
- [../ui/nspopover-decisions.md](../ui/nspopover-decisions.md) — why NSPopover, side-jump prevention, sheet/file-picker dismiss

---

## `panelVisibilityState` and `wrapEnv()`

> Regression guard ref: issue #377  
> See also: `AppDelegate.swift`, `PanelMainView.swift`

`panelVisibilityState: PanelVisibilityState` is an `ObservableObject` that
mirrors `panelIsOpen`. It is injected into every SwiftUI view hierarchy via
`wrapEnv()` so views can react to open/close without a direct reference to
`AppDelegate`.

- ❌ NEVER remove `panelVisibilityState`.
- ❌ NEVER remove `.environmentObject(panelVisibilityState)` from `wrapEnv()`.
- ❌ NEVER pass panel open state as a plain `Bool` prop to `PanelMainView`.

---

## `@MainActor` isolation on `AppDelegate`

> Regression guard ref: Swift 6 concurrency migration  
> See also: `AppDelegate.swift`, `AppDelegate+Navigation.swift`

`AppDelegate` is annotated `@MainActor`. This gives the Swift 6 compiler static
proof that all methods and stored properties are main-thread-only, eliminating
the need for runtime `DispatchQueue.main` assertions throughout.

The `nonisolated` blocking helper `enrichStepsIfNeeded` in
`AppDelegate+Navigation.swift` is intentionally exempt — it performs blocking
network I/O and is always dispatched onto `DispatchQueue.global()`.

- ❌ NEVER remove `@MainActor` from the `AppDelegate` class declaration.
- ❌ NEVER remove `nonisolated` from `enrichStepsIfNeeded`.

---

## Nav-state persistence across panel close/open

> Regression guard ref: issue #385  
> See also: `AppDelegate.swift` `closePanel()`

`savedNavState` is preserved across close so `openPanel()`'s `validatedView`
path navigates back to the same view on re-open. On close, `rootView` is always
reset to `mainView()` (so the SwiftUI tree is fresh), but `savedNavState` is
kept — `openPanel()` reads it and calls `navigate(to: validatedView(for: saved))`.

- ❌ NEVER clear `savedNavState` inside `closePanel()` or `hidePanel()`.
- ❌ NEVER try to preserve sheet `@State` across an explicit close (`closePanel()`) — see [nspopover-decisions.md](../ui/nspopover-decisions.md).
- Sheet `@State` IS preserved across `hidePanel()` (outside-tap / workspace-switch) via `hidePopoverWindowsPreservingSheets()` — this is intentional.

---

## OAuth URL handling

> Ref: issue #597  
> See also: `AppDelegate.swift` `application(_:open:)`

The `application(_:open:)` delegate searches the **full** `urls` array for the
`runbot://oauth/callback` URL rather than assuming `urls.first`. macOS may
deliver multiple URLs and the OAuth callback may not be first, which would leave
the sign-in spinner stuck indefinitely.

---

## `KeyablePanel` access level

> See also: `KeyablePanel.swift`, `AppDelegate.swift`

`KeyablePanel` must be `internal` (not `private` or `fileprivate`).
`AppDelegate+Navigation.swift` accesses `panel: KeyablePanel?` from a separate
file, and Swift `private` does not cross file boundaries.
