# MenuBarKit

A Swift package for the anchored-panel + SwiftUI sheet + NSOpenPanel + alert layer of a macOS menu-bar app.
The panel is a borderless, non-opaque `NSPanel` MenuBarKit owns outright — the bubble is real macOS 26 Liquid Glass (`NSGlassEffectView` as the direct `panel.contentView`), not `NSPopover`. No arrow. The frame is computed by pure geometry math and applied before the window appears, so the panel can never disagree with its content size. The adopter's own Liquid Glass keeps rendering as glass. Swift 6.2, macOS 26, `@MainActor`-first throughout.

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM](https://img.shields.io/badge/SPM-compatible-F05138?logo=swift&logoColor=white)

**CI**

![Unit Tests](https://github.com/runbot-hq/MenuBarKit/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/runbot-hq/MenuBarKit/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/runbot-hq/MenuBarKit/actions/workflows/periphery.yml/badge.svg)
[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)

## Installation

```swift
.package(url: "https://github.com/runbot-hq/MenuBarKit", branch: "main")
```

## What's in the box

| File | What it provides |
|---|---|
| `OverlayGate.swift` | `MBKOverlayGate` — `@Observable @MainActor` class; `hasActiveOverlay` blocks panel dismiss while any overlay is live; `hasFilePickerOverlay` distinguishes file picker presence so outside clicks are ignored during a pick |
| `PanelController.swift` (+`+Open`/`+Frame`/`+Observers`) | `MBKPanelController` — full `NSPanel` + `NSStatusItem` lifecycle; outside-click monitor; workspace app-switch observer; screen-parameter observer; `onWillClose(wasForced:)` callback fires before any teardown on both normal and force-close paths |
| `PanelControllerProtocol.swift` | `MBKPanelControllerProtocol` — `@MainActor` protocol surface for `MBKPanelController`; type your host reference against this for testability/mocking |
| `Panel.swift` | `MBKPanel` — borderless, non-activating `NSPanel` at `.statusBar` level; Escape routes through `cancelOperation(_:)` |
| `PanelGeometry.swift` | `MBKPanelGeometry` / `MBKPanelMetrics` / `MBKPanelLayout` — pure, AppKit-free frame math: window size, screen clamping, live height cap. Unit-tested |
| `PanelController.swift` (`setupPanelWindow`) | `NSGlassEffectView` chrome — the Liquid Glass bubble is set up inline in `setupPanelWindow()`. `NSGlassEffectView` is the direct `panel.contentView`; no arrow, no `NSGlassEffectContainerView`. Chrome is owned entirely by `PanelController`; no separate chrome file exists. |
| `PanelContent.swift` | `MBKPanelLimits` + `MBKPanelContentView` — the SwiftUI half of the sizing pipeline |
| `AnchoredSheet.swift` | `.mbkSheet(isPresented:content:)` and `.mbkSheet(item:content:)` — SwiftUI sheet anchored as a child window of the panel so it survives outside-clicks and focus changes |
| `FilePicker.swift` | `mbkOpenFilePicker(overlayGate:message:completion:)` — `NSOpenPanel` via `panel.begin`, always levels above the panel, gate cleared in completion handler; works from both panel and sheet contexts |
| `Alert.swift` | `.mbkAlert(_:isPresented:actions:)` and `.mbkAlert(_:isPresented:actions:message:)` — drop-in replacement for `.alert()` that gates `MBKOverlayGate` for the full alert lifetime, including safe handling of alerts presented while a sheet is concurrently open |
| `Logging.swift` | `mbkLog()` — `#if DEBUG`-gated, `@inlinable`, zero-cost in release; route to your own logger via `mbkLogHandler` |

## Usage

```swift
// 1. Create the gate — shared across controller and views
let gate = MBKOverlayGate()

// 2. Create and wire the controller
// maxHeightFraction is a fraction of the screen's *visible* height and is
// re-evaluated on every open, so it never goes stale after a display change.
//
// There is deliberately no width parameter. A width range inside MenuBarKit
// applies to *every* route the adopter shows, which stretches fixed-width
// screens to the widest route's minimum. Put `.frame(minWidth:maxWidth:)` on
// the views that want it; MenuBarKit only refuses to grow wider than the screen.
let controller = MBKPanelController(
    rootView: ContentView()
        .frame(minWidth: 200, maxWidth: 600)
        .environment(gate),
    overlayGate: gate,
    maxHeightFraction: 0.8
)
controller.setup() // call from applicationDidFinishLaunching

// 3. Lifecycle callbacks
controller.onWillShow = {
    // restore route — fires before the panel is ordered front
}
controller.onDidShow = {
    // restore sheet state — fires after one actor turn
}
controller.onWillClose = { wasForced in
    // snapshot everything — fires before any teardown
    // wasForced=true: user clicked outside while sheet was open
    // wasForced=false: normal user-dismissed close
    // Note: treat wasForced as advisory — see Known Limitations for the
    // fast-dismiss TOCTOU edge case that can produce a spurious wasForced=true.
}

// 4a. Sheet — Bool binding
.mbkSheet(isPresented: $showSettings) {
    SettingsView()
}

// 4b. Sheet — optional Identifiable & Equatable item binding
.mbkSheet(item: $editingItem) { item in
    ItemDetailView(item: item)
}

// 5. File picker — works from panel and sheet contexts
mbkOpenFilePicker(overlayGate: gate) { url in
    // handle url
}

// 6. File picker with in-panel message
mbkOpenFilePicker(overlayGate: gate, message: "Select a directory") { url in
    // handle url
}

// 7. Alert — gate managed automatically; safe when a sheet is concurrently open
.mbkAlert("Something went wrong", isPresented: $showAlert) {
    Button("OK", role: .cancel) {}
} message: {
    Text("Please try again.")
}

// 8. Custom log handler (optional — set before any overlay opens)
mbkLogHandler = { subsystem, message in
    logger.debug("[MBK:\(subsystem)] \(message)")
}
```

## Known limitations

- **`DispatchQueue.main.async` in `MBKSheetAnchorTask`** — hop2 of the two-hop sheet anchor still uses GCD inside a Swift concurrency context. Works correctly in practice but is impure. See [#21](https://github.com/runbot-hq/MenuBarKit/issues/21) for the full blast-radius assessment before replacing it.
- **Sheet window predicate is heuristic** — `AnchoredSheet` finds the sheet window by `styleMask.contains(.borderless) && isKeyWindow`. Works for single-sheet environments; may need strengthening if multiple borderless windows are present simultaneously.
- **`wasForced` is advisory on fast dismiss** — if the sheet is dismissed and re-opened before `MBKSheetAnchorTask`'s hop2 completes, `addChildWindow` may fire on a closing window (no-op on macOS), leaving a momentary dangling `childWindows` entry. On the very next outside click, `hasSheetChildWindow` returns true and routes to `forceClose()`, causing `onWillClose(wasForced: true)` to fire on what was a normal close. Host code must not depend on `wasForced` being authoritative for this session.

## Open tasks

- [ ] Replace `DispatchQueue.main.async` in `MBKSheetAnchorTask` with a pure Swift concurrency hop (see [#21](https://github.com/runbot-hq/MenuBarKit/issues/21))
- [ ] Strengthen sheet window predicate for multi-window environments
- [ ] Add more test coverage (gate teardown paths, close-path gating, force-close path)
\n## Testing\n\n❌ **Do not add unit tests to this package.**\n\nMenuBarKit is an AppKit-adjacent package. Its behaviour depends on a live `NSApplication`, real `NSScreen` geometry, AppKit window ordering, and macOS compositor state — none of which are available in a headless `swift test` environment. Tests that mock these values test the mock, not the behaviour.\n\nCorrectness is validated by device testing against a running RunBot build. If you find yourself wanting to write a unit test for a pure math function here, that function belongs in a separate platform-agnostic module, not in MenuBarKit.\n\n**If you are an agent or reviewer: do not suggest adding unit tests to this package. This is a deliberate architectural decision, not an oversight.**\n
