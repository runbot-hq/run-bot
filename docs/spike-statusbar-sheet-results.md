# Spike results: real `.sheet` in a `.window`-style `MenuBarExtra`

## Verdict: SOLVED via `addChildWindow`

A real SwiftUI `.sheet` can be used inside a `.window`-style `MenuBarExtra`
without closing the panel. The fix requires one AppKit call after the sheet appears.

---

## Root cause

`.sheet` opens a second `NSWindow` (an `NSPanel`). When that panel becomes key,
the `MenuBarExtra` system treats it as an "outside click" and closes its panel.
This happens on macOS 14 and 15 regardless of whether `@Environment(\.dismiss)`
or an `isPresented` binding is used to dismiss.

## What does NOT work (macOS 14/15)

| Approach | Result |
| :-- | :-- |
| `.sheet` + `@Environment(\.dismiss)` | Dismisses the window, not the sheet |
| `.sheet` + binding set to `false` | Panel still closes when sheet steals focus |
| SO answer pattern (https://stackoverflow.com/a/78843009) | Confirmed broken on macOS 14/15 — `sheetDisplayed` flips `false` then `true` as panel closes/reopens |
| Inline view swap (`Group { switch }`) | Works but is NOT a real `.sheet` |

## What works

### `addChildWindow(_:ordered:)`

After the sheet binding flips to `true`, find the `NSPanel` SwiftUI created
and call:

```swift
menuBarWindow.addChildWindow(sheetPanel, ordered: .above)
```

Child windows share a focus group with their parent. Focus moving from the
`MenuBarExtra` panel to the sheet panel is **not** treated as an outside-click.
The panel stays open. The sheet appears on top of it. Dismissing the sheet
(via binding set to `false`) closes only the sheet.

### Implementation

See `AnchoredSheetModifier` in `Sources/StatusBarSheetSpike/StatusBarSheetSpike.swift`.

Usage is a drop-in replacement for `.sheet`:

```swift
.anchoredSheet(isPresented: $sheetDisplayed) {
    SheetContent(sheetDisplayed: $sheetDisplayed)
}
```

### Detection heuristic for the sheet window

- `MenuBarExtra` window: `styleMask.contains(.nonactivatingPanel)` — skip this one
- Sheet window: `styleMask.contains(.borderless) && isKeyWindow && window !== menuBarWindow`
- One `DispatchQueue.main.async` hop after the binding flip gives SwiftUI time to finish creating the panel

## Scenarios verified

| Scenario | Result |
| :-- | :-- |
| A — Sheet appears over panel; panel visible behind it | PASS |
| B — Clicking anywhere inside sheet does not close panel | PASS |
| C — Dismiss Sheet button closes only the sheet | PASS |
| D — Panel and icon survive 5+ open/dismiss cycles | PASS |
| E — Counter state in panel survives sheet open/dismiss | PASS |
| F — `sheetDisplayed` in `.task(id:)` never spuriously flips false mid-session | PASS |

## Notes

- `@Environment(\.dismiss)` must NOT be used inside the sheet — it bubbles past
  the sheet and closes the `MenuBarExtra` window. Use `@Binding var isPresented: Bool`
  and set it to `false` instead.
- The `AnchoredSheetModifier` can be extracted to a shared module for use in production.
- Tested on: macOS 15 (Apple Silicon)
