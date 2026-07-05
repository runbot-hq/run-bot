# RunBot Swift Commenting Standard

## Guiding Principles

The codebase has three audiences for documentation: **contributors reading the code**, **Xcode Quick Help**, and **a future DocC site**. The standard must serve all three. There are three comment styles in use — `///` doc comments, `//` inline remarks, and `// MARK:` section dividers — and this standard normalizes their application across all layers of the codebase.

---

## Rule 1 — `///` on All Declarations

Every `struct`, `class`, `enum`, `protocol`, `typealias`, `func`, computed `var`, stored `var`, `@State`, `@ObservedObject`, `@Published`, `init`, and `body` declaration gets a `///` doc comment. No exceptions based on access level or perceived obviousness.

The opening sentence is a **one-line summary** in imperative or declarative form. A blank `///` line separates the summary from any body paragraph, matching Apple's own SDK header style.

```swift
/// Aggregate of all active-scope runners and their workflow jobs.
/// Polling is driven by a self-rescheduling `Timer`; interval adapts based on
/// whether any jobs are in-progress or the API is rate-limited.
///
/// - Note: Always accessed on `@MainActor`. All mutations are main-thread only.
/// - SeeAlso: `ScopeStore`, `RunnerLifecycleService`, `PollResultBuilder`
@MainActor
final class RunnerStore { … }
```

```swift
/// The up-to-date entry from `ScopeStore`, or `nil` if the scope has been
/// removed since this view was created.
private var liveEntry: ScopeEntry? {
    scopeStore.entries.first(where: { $0.id == scopeEntry.id })
}
```

```swift
/// SwiftUI body. Renders the full settings detail screen for the scope,
/// including header bar, info, monitoring, failure hook, and danger sections.
var body: some View { … }
```

```swift
/// The branch currently selected as the failure-hook filter.
/// `nil` means no filter is active — the hook fires for all branches.
@State private var hookBranch: String?
```

---

## Rule 2 — Structured DocC Tags

Use DocC callout tags consistently. Every applicable tag must be present — do not omit `- Returns:` on non-void functions or `- Parameter:` on non-obvious parameters.

| Tag | When to use |
|---|---|
| `- Parameter name:` | Single parameter that needs explanation |
| `- Parameters:` (block) | Two or more parameters |
| `- Returns:` | Any non-void return where the value shape or contract matters |
| `- Throws:` | Any `throws` or `async throws` function |
| `- Note:` | Threading, actor, ordering, or lifecycle contracts |
| `- Important:` | Must-not-break invariants |
| `- SeeAlso:` | Cross-type relationships and related declarations |

```swift
/// Builds two lookup maps from the registered local runner list.
///
/// - Parameters:
///   - scopes: The active scope strings from `ScopeStore`.
///   - localRunners: Snapshot of locally discovered runners.
/// - Returns: A tuple of `(byFullKey, byName)` where `byFullKey` uses
///   `"scope/runnerName"` as the key and `byName` uses runner name only.
/// - Note: The name-only map is a fallback for org-scoped runners whose
///   `ScopeStore` scope string may not match the fetch-time scope prefix.
/// - SeeAlso: `fetchAndEnrichRunners(scopes:installPathByName:installPathByRunnerName:)`
private func buildInstallPathMap(
    scopes: [String],
    localRunners: [RunnerModel]
) -> (byFullKey: [String: String], byName: [String: String]) { … }
```

```swift
/// Fires the failure hook if all preconditions pass: hook enabled, branch
/// filter matched, and at least one run has a failure conclusion.
///
/// - Parameters:
///   - group: The workflow action group that just completed.
///   - scope: The scope string (e.g. `"owner/repo"`) the group belongs to.
///   - callsite: Debug label identifying where this was triggered from.
/// - Important: All `$TOKEN` variables must be fully resolved in Swift before
///   the command string reaches `/bin/zsh -c`. No shell variables or `$()`
///   subshells may remain — special characters in log content would break parsing.
/// - Note: Dispatches to a background thread internally. Safe to call from `@MainActor`.
static func fireIfNeeded(group: WorkflowActionGroup, scope: String, callsite: String = "unknown") { … }
```

---

## Rule 3 — Inline `//` Comments: Intent and Constraints Only

Plain `//` comments inside function bodies explain **decisions and constraints**, never restate what the code does. Issue and PR references (`// #560: Branch filter`) are encouraged and must be kept — they link runtime behaviour to the decision trail in git.

```swift
// ✅ Good — explains a non-obvious constraint
// Task.detached ensures the body runs off @MainActor so that
// urlSessionAPI's dispatchPrecondition(.notOnQueue(.main)) does not trap.
// A plain Task on a @MainActor type inherits the actor and stays on main.

// ❌ Bad — restates the code
// Invalidate the timer
timer?.invalidate()
```

```swift
// ✅ Good — issue reference links behaviour to a decision
// #560: Branch filter — skip if a branch filter is set and doesn't match
let filterBranch = ScopePreferencesStore.failureHookBranch(for: scope)
```

---

## Rule 4 — `// MARK:` Structure

Every file uses `MARK` dividers consistently. The required hierarchy:

```swift
// MARK: - TypeName            ← top of file, matches the primary type name

// MARK: Stored Properties     ← no leading dash for sub-sections within a type
// MARK: - Init
// MARK: - Derived / Computed
// MARK: - Actions
// MARK: - Private
```

Extension files use a dash for each extension block:

```swift
// MARK: - Sections
// MARK: - Failure Hook Rows
// MARK: - Sub-view Helpers
```

Every `extension` in a separate file or at the bottom of a file gets its own `// MARK: -` divider. No `extension` block is left unmarked.

---

## Rule 5 — File Header

Every file begins with a minimal standard header. Issue history belongs in git log, not the file top. Multi-line issue-log blocks (`// #544`, `// #546`…) should be removed from file headers and replaced with a type-level `///` doc comment so they surface in Xcode Quick Help instead.

```swift
// FailureHookRunner.swift
// RunBot
//
// Fires a per-scope terminal command when a WorkflowActionGroup transitions
// to a failure conclusion. Resolves all $TOKEN variables before shell handoff.
// See: TerminalLauncher, ScopePreferencesStore, WorkflowActionGroup
```

The `See:` line lists the primary collaborators so a new contributor knows where to look next without reading the full file.

---

## Rule 6 — The Only Exception

`// swiftlint:disable` suppression lines are tool directives, not declarations. They do not get `///` comments — leave them exactly as-is.

Everything else gets documented.
