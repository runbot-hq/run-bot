# MenuBarKit

A focused Swift package that owns the NSPopover + SwiftUI sheet + NSOpenPanel layer for a macOS menu-bar app.

Extracted from `RunBot` as part of PR #2037 to validate the patterns needed for the #2027/#2028 migration before touching the 13 k-line main app. The library is **Swift 6.2, macOS 26, `@MainActor`-first throughout**.

---

## Why this is a standalone package — and must stay one

This section exists because the question "why not just put this in `RunBot` directly?" will come up every time someone looks at the repo structure. The answer is not organisational preference — it is an engineering constraint.

### The problem domain is genuinely hard

Getting `NSPopover` + SwiftUI sheet + `NSOpenPanel` to behave correctly together requires solving several AppKit timing problems that are invisible until they aren't:

- Sheet windows must be attached as `addChildWindow` children of the popover window, or they float detached and trigger the outside-click monitor.
- The overlay gate must be armed *before* `beginSheetModal` to close the race window with `popoverShouldClose`.
- `DispatchQueue.main.async` in `anchorSheetWindow()` is currently a known placeholder — the correct fix (`NSWindow.didBecomeKeyNotification` or `AsyncStream`) requires careful iteration that cannot be done safely while the surrounding app is also running.
- The dismiss-safety gap (gate clearing before AppKit finishes tearing down the child-window relationship) is a timing issue that only manifests under specific tap sequences. Reproducing and fixing it inside a 13k-line app with polling, OAuth, SwiftUI nav, and runner state in flight is extremely difficult.

### Iterating inside the main app is the wrong environment

Every AppKit timing fix in this package requires:
1. Reproducing a race condition reliably
2. Verifying the fix doesn't introduce a new one
3. Building and running the app to observe the result

Inside `RunBot`, step 3 means compiling 126 files, launching the full app, and triggering the specific interaction path. Inside a standalone package with a minimal example app, step 3 means running ~50 lines of spike code in a dedicated executable.

The iteration speed difference is not marginal. The patterns in this package took significant effort to get to their current (still incomplete) state. The remaining work — dismiss-safety gap, `anchorSheetWindow` replacement, predicate strengthening, tests — will require the same kind of focused iteration.

### The zero-app-knowledge rule is structural, not a convention

MenuBarKit has no knowledge of `RunBot`, `RunBotCore`, runner state, `AppState`, or any app-specific type. This is enforced by the package boundary — `MenuBarKit` cannot import `RunBot` or `RunBotCore` even by accident. If this code lived in `Sources/RunBot/MenuBarKit/`, that boundary becomes a convention enforced only by code review. Conventions erode; package boundaries do not.

### The right lifecycle

1. Finish the outstanding migration checklist items (below) **in the standalone package**, with a minimal example app as the test harness.
2. Once the package is production-ready, the RunBot migration PR pulls it in as a resolved dependency.
3. RunBot never has to host the iteration work.

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

This package is **spike code** — it validates two specific unknowns for the migration:

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
- [ ] Add `MenuBarKitTests` target covering gate logic and teardown paths
- [ ] Update `PopoverLifecycleCoordinator` to use `queue: nil + Task { @MainActor }` to match MenuBarKit's strictly Swift 6-correct pattern (see `ASYMMETRY WITH MBKPopoverController` in `PopoverLifecycleCoordinator.swift`)
