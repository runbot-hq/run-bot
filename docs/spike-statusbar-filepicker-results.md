# Spike: file picker inside a `.window`-style `MenuBarExtra`

## Status: IN PROGRESS

## Goal

Verify that a file picker can be shown from a `.window`-style `MenuBarExtra`
without the panel closing when the user clicks inside the picker.

## Root cause

Same as `.sheet` in PR #2033: the picker creates a new `NSWindow` that becomes
key. `MenuBarExtra` treats any key-window change to a non-child window as an
"outside click" and closes its panel.

**Fix:** call `menuBarWindow.addChildWindow(pickerWindow, ordered: .above)`
before the picker is shown. Child windows share the parent's focus group —
focus moving to the picker is not treated as an outside-click.

## Two approaches under test

### A — `.fileImporter` + `AnchoredOpenPanelModifier`

`.onChange(of: isImporting)` detects the flip to `true`, waits one run-loop
turn for SwiftUI to create the picker `NSWindow`, then anchors it:

```swift
menuBarWindow.addChildWindow(pickerWindow, ordered: .above)
```

### B — `NSOpenPanel` anchored before `runModal()`

Finds the `MenuBarExtra` window, adds the panel as a child, calls `runModal()`,
then removes the child relationship after close.

## Scenarios to verify

| # | Scenario | Expected | Result |
| :-- | :-- | :-- | :-- |
| A1 | Picker appears; clicking inside does NOT close panel | ✅ | ⬜ |
| A2 | Cancel → panel still open, label shows "(none)" | ✅ | ⬜ |
| A3 | Pick a file → panel still open, label updates | ✅ | ⬜ |
| A4 | Panel survives 5+ open/cancel cycles | ✅ | ⬜ |
| B1 | Picker appears; clicking inside does NOT close panel | ✅ | ⬜ |
| B2 | Cancel → panel still open, label unchanged | ✅ | ⬜ |
| B3 | Pick a file → panel still open, label updates | ✅ | ⬜ |
| B4 | Panel survives 5+ open/cancel cycles | ✅ | ⬜ |

## To run

```bash
git checkout spike/statusbar-filepicker
swift run StatusBarFilePickerSpike
```

Click the **folder.badge.plus** icon → window panel opens.

## Notes

- If approach A still closes the panel, the picker window may not be `.isKeyWindow`
  yet in the one-turn async hop — try a second `DispatchQueue.main.async` hop.
- The `AnchoredFileImporter` helper can be extracted to a shared module for
  production use, same as `AnchoredSheetModifier` from PR #2033.
- Tested on: _(fill in macOS version + chip)_
