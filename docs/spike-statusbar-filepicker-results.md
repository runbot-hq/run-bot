# Spike: NSOpenPanel from a statusbar (accessory) app

## Status: IN PROGRESS

## Goal

Verify that `NSOpenPanel` can be reliably shown from a menubar-only app
(`.accessory` activation policy, no Dock icon) and that the panel comes
to the front correctly without extra user interaction.

## Background

Menubar apps use `NSApplication.ActivationPolicy.accessory`. macOS does not
consider them "active" in the traditional sense, so `NSOpenPanel.runModal()`
can appear behind other windows unless the app is explicitly activated first.

## Approach

```swift
NSApp.setActivationPolicy(.regular)
NSApp.activate(ignoringOtherApps: true)
let result = panel.runModal()
NSApp.setActivationPolicy(.accessory)
```

Temporarily promote to `.regular` before the panel, restore to `.accessory`
afterward. This is the standard workaround.

## Scenarios to verify

| Scenario | Expected | Result |
| :-- | :-- | :-- |
| Panel appears in front of other windows | ✅ | ⬜ |
| Panel is key / focusable immediately | ✅ | ⬜ |
| Cancel returns nil | ✅ | ⬜ |
| OK returns correct URL | ✅ | ⬜ |
| Status icon survives open/cancel cycle | ✅ | ⬜ |
| No Dock icon while panel is closed | ✅ | ⬜ |
| Dock icon disappears after panel closes | ✅ | ⬜ |

## To run

```bash
git checkout spike/statusbar-filepicker
swift run StatusBarFilePickerSpike
```

Click the **folder.badge.plus** icon in the menu bar → **Pick File…**

## Notes

- `allowedFileTypes` is deprecated on macOS 12+; swap for `allowedContentTypes: [UTType]` when integrating into the main target.
- If the panel still renders behind windows on your OS version, try adding a short `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` before `runModal()`.
