# AGENTS.md

Context for AI coding agents working on **RunBot**. Read this first. If code and this file
disagree, the code wins — flag the doc so it can be fixed.

RunBot is a macOS 26 menu-bar app (Swift 6.2, SwiftPM, AppKit + SwiftUI) that monitors and
manages GitHub Actions self-hosted runners.

## Commands

Run these and make them pass **before** calling any change done. CI runs the exact commands below
— match them, including flags.

```bash
swift build                                   # type-check the whole package
swift test                                    # run all test suites (RunBotCoreTests + AppUpdaterTests)
swiftlint lint --strict                       # CI fails on warnings, not just errors
periphery scan                                # dead-code scan (config: .periphery.yml)
swift run                                      # build + launch the app locally
bash build.sh                                  # release build + .app bundle (arm64 only)
```

> ⚠️ **The three things agents get wrong here — read carefully:**
>
> 1. **SwiftLint runs with `--strict`.** A bare `swiftlint` passes locally while CI fails, because
>    `--strict` promotes every warning to an error. Always run `swiftlint lint --strict`.
> 2. **Tests run with bare `swift test`.** This covers all SPM test targets: `RunBotCoreTests`
>    and `AppUpdaterTests`. The UI tests (`RunBotUITests`) run separately via `xcodebuild` on the
>    self-hosted runner — do **not** try to run them with `swift test`.
> 3. **Periphery uses `retain_public: true`** scoped to the `RunBot`, `RunBotCore`, and
>    `AppUpdater` targets (test targets excluded). Don't "fix" a Periphery finding by making a
>    symbol non-public if the app target needs it; mark intentional keeps with
>    `// periphery:ignore` instead.
>
> Tooling is installed via `brew install swiftlint` and
> `brew install peripheryapp/periphery/periphery`. CI runs on `macos-26`.

## SwiftLint rules that bite (config: `.swiftlint.yml`)

These opt-in rules fail CI and are the most common agent mistakes:

- **`file_header`** — every Swift file's first two lines must match
  `// <Filename>.swift` then `// RunBot` or `// AppUpdater`. New files without this header fail
  the strict lint.
- **`missing_docs`** — every declaration needs a `///` doc comment. Don't add public/internal API
  without one.
- **`sorted_imports`** — keep `import` statements alphabetised.
- **`large_tuple`** — tuples with 3+ members are banned; this is why `IndexedScopedRunner` exists
  instead of a 3-tuple. Introduce a small struct rather than widening a tuple.
- Size limits: `line_length` warns at 200, `function_body_length` at 90, `type_body_length` at 400
  (all being tightened in #1406). `todo` and `trailing_comma` are disabled.

Don't reformat unrelated code to satisfy the linter — keep diffs scoped to your change.

## Project layout

Two targets plus a test target (full map: `docs/architecture/file-hierarchy.md`):

```
Sources/RunBotCore/   library — pure logic, no UI; the testable core
Sources/RunBot/       executable — AppKit/SwiftUI app; depends on RunBotCore
Tests/RunBotCoreTests/ swift-testing suite (+ TestSupport doubles & fixtures)
```

**Hard rule: `RunBotCore` must never import the `RunBot` app target.** App-layer
dependencies are injected into Core via protocols and closures (`RunnerPollerProtocol`,
`RunnerViewModelProtocol`, the `*StoreProtocol`s). This boundary is load-bearing.

Keep files small and single-responsibility — **add new files / extensions, don't grow existing
ones**. That's why `AppDelegate`, `AddRunnerSheet`, and `RunnerPoller` are split across many files.

## Architecture & data flow

- **Actor-based, no Combine.** `RunnerPoller` (Core actor) owns the poll loop and writes results
  into an injected `@MainActor @Observable RunnerState`; SwiftUI observes it directly. There is no
  `PassthroughSubject` and no `RunnerViewModel` push-coupling.
- **Immutable, `Sendable` value models** (`Runner`, `RunnerModel`, config types): `let` properties,
  mutate via `copying(…)`. No `@unchecked Sendable` in production types except the documented
  sign-off on `PollLoopCoordinator`.
- See `docs/architecture/ARCHITECTURE.md` for the data model, concurrency model, and library rationale detail, and `docs/principles/project-tech-principles.md` for the canonical 21 principles this codebase commits to.

## GitHub networking & auth

- **Do not shell out to `gh api`.** Networking goes through a `URLSession`-based transport
  (`GitHubTransportProtocol` / `GitHubURLSessionTransport`), with typed `Codable` decoding, the
  `GitHubRateLimitHandler` actor, and Link-header pagination (`ghAPIPaginated`).
- In tests, inject a stub conforming to `GitHubTransportProtocol` (see `GitHubTransportShimTests`
  and `StubURLProtocol`). Never hit the live network in tests.
- **Auth** is resolved by `GitHubTokenCache` / `OAuthService`, priority order: in-app OAuth
  sign-in (Keychain) → `GH_TOKEN` → `GITHUB_TOKEN`. `gh auth login` / `gh auth token` is **not**
  a supported path (removed in Batch 18) — don't reference it in code, strings, or docs.

## UI notes

- Menu-bar-only (no Dock icon). Dot colour reflects `AggregateStatus`.
- **Popover side-jump is a known hazard.** Before touching panel sizing/anchoring, read
  `docs/ui/popover-side-jump-prevention.md` and `docs/ui/nspopover-dynamic-width.md`, and respect
  the regression guards in `PanelMainView` / `PanelVisibilityState` (refs #375–377).
  Sheets/dismiss: `docs/ui/nspopover-dismiss-and-sheets.md`.
- Follow the macOS 26 Liquid Glass design system (`DesignTokens`, `PanelViewModifiers`); support
  dark & light mode.

## Boundaries (do not touch)

- **Generated / tooling-owned:** the `.xcodeproj` is generated by XcodeGen from `project.yml` —
  edit `project.yml` then run `xcodegen generate`; never hand-edit the `.xcodeproj`.
- **`build.sh` arch pinning:** it targets `--arch arm64` with an explicit build path on purpose.
  Do not revert to an arch-neutral path (it caused stale-artifact debugging).
- **Dependencies:** only `apple/swift-collections` is allowed. Do not add third-party deps without
  asking.
- **Don't disable lint rules or delete regression guards** to make a build pass — fix the cause.
- Never commit secrets or tokens.

## When unsure

- Prefer the simplest change that respects the Core/app boundary and value-semantics rules.
- Add focused files rather than enlarging existing ones.
- Don't add features or dependencies not described here — ask first.
