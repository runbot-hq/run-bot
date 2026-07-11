# Spike: file picker inside a `.window`-style `MenuBarExtra`

## Status: IN PROGRESS

## Goal

Verify that a file picker can be reliably shown from a `.window`-style
`MenuBarExtra` (SwiftUI popover panel) and that the panel stays open
while the picker is active.

## Two approaches under test

### A — SwiftUI `.fileImporter`

Wired directly to a `Button` inside the `ContentView`. Native SwiftUI API.
The open panel is presented as a sheet attached to the `MenuBarExtra` window.

### B — `NSOpenPanel` + activation-policy dance

Fallback for cases where `.fileImporter` closes the panel:

```swift
NSApp.setActivationPolicy(.regular)
NSApp.activate(ignoringOtherApps: true)
let result = panel.runModal()
NSApp.setActivationPolicy(.accessory)
```

## Scenarios to verify

| # | Scenario | Expected | Result |
| :-- | :-- | :-- | :-- |
| A1 | `.fileImporter` picker appears while panel stays open | ✅ | ⬜ |
| A2 | Cancel → picked URL stays nil | ✅ | ⬜ |
| A3 | OK → label updates to file name | ✅ | ⬜ |
| A4 | Panel survives 5+ open/cancel cycles | ✅ | ⬜ |
| B1 | `NSOpenPanel` appears in front of all other windows | ✅ | ⬜ |
| B2 | Cancel → picked URL stays nil | ✅ | ⬜ |
| B3 | OK → label updates to file name | ✅ | ⬜ |
| B4 | Dock icon disappears after panel closes | ✅ | ⬜ |
| B5 | Panel survives 5+ open/cancel cycles | ✅ | ⬜ |

## To run

```bash
git checkout spike/statusbar-filepicker
swift run StatusBarFilePickerSpike
```

Click the **folder.badge.plus** icon in the menu bar to open the window panel.

## Notes

- If `.fileImporter` closes the `MenuBarExtra` panel, the `AnchoredSheetModifier`
  pattern from `spike/statusbar-sheet-swiftui` (PR #2033) may be needed here too.
- `allowedContentTypes: [.item]` accepts all file types; narrow as needed.
- Tested on: _(fill in macOS version + chip)_
