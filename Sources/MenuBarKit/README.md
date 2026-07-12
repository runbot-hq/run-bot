# MenuBarKit

A focused Swift package target that owns the NSPopover + SwiftUI sheet + NSOpenPanel layer for a macOS menu-bar app.

Extracted from `RunBot` as part of PR #2037 to validate the patterns needed for the #2027/#2028 migration before touching the 13 k-line main app. The library is **Swift 6.2, macOS 26, `@MainActor`-first throughout**.

---

## What lives here

| File | Responsibility |
|---|---|
| `OverlayGate.swift` | `MBKOverlayGate` — single `@Observable @MainActor` class; one `Bool` that blocks popover dismiss while any overlay is live |
| `PopoverController.swift` | `MBKPopoverController` — full NSPopover + NSStatusItem lifecycle; outside-click monitor; workspace app-switch observer |
| `AnchoredSheet.swift` | `MBKAnchoredSheetModifier` / `.mbkSheet()` — presents a SwiftUI sheet anchored as a child window of the popover so it survives outside-clicks |
| `FilePicker.swift` | `mbkOpenFilePicker()` — opens NSOpenPanel via `beginSheetModal` anchored to the correct window (popover or sheet child); manages the overlay gate |
| `Logging.swift` | `mbkLog()` — `#if DEBUG`-gated, `@inlinable` zero-cost no-op in release |

---

## Spike status

This target is **spike code** — it validates two specific unknowns for the migration:

1. Sheet anchoring over an NSPopover + dismiss blocking
2. NSOpenPanel attachment from both popover and sheet level

Every known limitation is documented inline with `// SPIKE ONLY`, `#warning`, or a `TARGET IMPLEMENTATION` comment. The most important ones:

- **`AnchoredSheet` dismiss-safety gap** — `overlayGate.hasActiveOverlay` clears before the sheet NSWindow is fully detached. See `DISMISS-SAFETY GAP` in `AnchoredSheet.swift`. Do not paper over with a delay; the fix is `NSWindow.didBecomeKeyNotification` — deferred to the migration PR.
- **`DispatchQueue.main.async` in `anchorSheetWindow()`** — mixes GCD with Swift concurrency. Gated by `#warning`. Replace with the notification-based approach in the migration PR.
- **`sheetChildWindow` predicate** — intentionally weak for spike lifetime; see `sheetChildWindow PREDICATE` in `FilePicker.swift` before strengthening.

---

## Usage (spike wiring — see `RunBotSpike/`)

```swift
// 1. Create the gate (shared across controller + views)
let gate = MBKOverlayGate()

// 2. Create and set up the controller
let controller = MBKPopoverController(rootView: RootView(), overlayGate: gate)
controller.setup()   // ← must be called from applicationDidFinishLaunching

// 3. Present a sheet from any view — gate managed automatically
.mbkSheet(isPresented: $showSettings, overlayGate: gate) { SettingsView() }

// 4. Open a file picker from popover context
mbkOpenFilePicker(target: .popover, overlayGate: gate) { url in … }

// 5. Open a file picker from sheet context
mbkOpenFilePicker(target: .sheet, overlayGate: gate) { url in … }
```

---

## Migration checklist (before porting to main app)

- [ ] Replace `DispatchQueue.main.async` in `anchorSheetWindow()` with `NSWindow.didBecomeKeyNotification` (see `TARGET IMPLEMENTATION` in `AnchoredSheet.swift`)
- [ ] Fix the dismiss-safety gap — tie gate lifetime to window lifecycle, not SwiftUI binding state
- [ ] Strengthen `sheetChildWindow` predicate for multi-child-window environments
- [ ] Add `.platforms([.macOS(.v26)])` to the `MenuBarKit` target in `Package.swift`
- [ ] Add `MenuBarKitTests` target covering gate logic and teardown paths (P13)
- [ ] Update `PopoverLifecycleCoordinator` to use `queue: nil + Task { @MainActor }` to match MenuBarKit's strictly Swift 6-correct pattern (see `ASYMMETRY WITH MBKPopoverController` in `PopoverLifecycleCoordinator.swift`)
