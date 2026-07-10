## Contents

- [Stacked PRs](#stacked-prs)
- [The Mental Model](#the-mental-model)
- [Creating the Stack](#creating-the-stack)
- [Keeping the Stack in Sync](#keeping-the-stack-in-sync)
- [Making Changes to a Middle Branch](#making-changes-to-a-middle-branch)
- [Landing the Stack](#landing-the-stack-merging-without-conflict-fuss)
- [Conflict Prevention Checklist](#conflict-prevention-checklist)
- [If a Conflict Does Occur During Rebase](#if-a-conflict-does-occur-during-rebase)
- [Landing with --onto (squash-merge stacks)](#landing-with---onto-squash-merge-stacks)
- [Code Comments](#code-comments)

---

## Stacked PRs

Stacked PRs let you break large features into small, reviewable slices that build on each other. Each PR targets the one before it, not `main`. This doc covers how we create, manage, and land a stack cleanly.

---

## The Mental Model

```
main
 └── feature/auth-base          (PR 1 → targets main)
      └── feature/auth-ui        (PR 2 → targets feature/auth-base)
           └── feature/auth-tests (PR 3 → targets feature/auth-ui)
```

Each branch is a child of the one above it. PRs are reviewed and merged **bottom-up**: PR 1 lands first, then PR 2 retargets `main`, then PR 3, etc.

---

## Creating the Stack

```bash
# Start from main
git checkout main && git pull

# PR 1 — base layer
git checkout -b feature/auth-base
# ... make changes ...
git push -u origin feature/auth-base
# Open PR targeting main

# PR 2 — builds on PR 1
git checkout -b feature/auth-ui
# ... make changes ...
git push -u origin feature/auth-ui
# Open PR targeting feature/auth-base  ← NOT main

# PR 3 — builds on PR 2
git checkout -b feature/auth-tests
# ... make changes ...
git push -u origin feature/auth-tests
# Open PR targeting feature/auth-ui  ← NOT main
```

**Rule:** Every PR in the stack targets its parent branch, never `main` directly (until it's the bottom of the stack ready to land).

---

## Keeping the Stack in Sync

When `main` gets new commits, rebase the whole stack from the bottom up:

```bash
# Update the base branch first
git checkout feature/auth-base
git rebase origin/main
git push --force-with-lease

# Then each child, in order
git checkout feature/auth-ui
git rebase feature/auth-base
git push --force-with-lease

git checkout feature/auth-tests
git rebase feature/auth-ui
git push --force-with-lease
```

**Always use `--force-with-lease`**, never `--force`. It prevents overwriting commits someone else may have pushed.

When a reviewer leaves commits or suggestions on a PR mid-stack, incorporate them on that branch, then cascade the rebase downward through all children.

---

## Making Changes to a Middle Branch

If review feedback touches PR 2 (a middle branch):

```bash
git checkout feature/auth-ui
# Make the fix
git add . && git commit -m "fix: address review feedback"
git push --force-with-lease

# Cascade down to all children
git checkout feature/auth-tests
git rebase feature/auth-ui
git push --force-with-lease
```

Never amend commits that are already the base of another branch without immediately cascading the rebase.

---

## Landing the Stack (Merging Without Conflict Fuss)

The golden rule: **merge bottom-up, retarget immediately**.

### Step 1 — Land PR 1

Merge PR 1 into `main` on GitHub (squash or merge commit, whichever the project uses consistently).

### Step 2 — Retarget PR 2

On GitHub, change PR 2's base from `feature/auth-base` → `main`. GitHub will show the diff correctly because `feature/auth-base`'s commits are now in `main`.

Then locally:

```bash
git checkout feature/auth-ui
git rebase origin/main   # rebase onto the freshly updated main
git push --force-with-lease
```

### Step 3 — Repeat up the stack

Merge PR 2, retarget PR 3 to `main`, rebase locally, push. Repeat until the stack is fully landed.

---

## Conflict Prevention Checklist

- [ ] **Keep slices small.** Each PR should touch one concern. The bigger the PR, the more likely conflicts accumulate.
- [ ] **Rebase onto `main` daily** when `main` is active. Don't let the base drift.
- [ ] **Never merge `main` into a stack branch** — always rebase. Merge commits in the middle of a stack create a tangled history that is very hard to untangle later.
- [ ] **Use `--force-with-lease`** on every forced push.
- [ ] **Retarget on GitHub immediately** after a bottom PR lands — don't leave stale base branches referenced.
- [ ] **Delete merged branches** promptly so the stack topology stays clear.

---

## If a Conflict Does Occur During Rebase

```bash
git rebase origin/main
# ... conflict ...

# Fix the conflict in your editor, then:
git add <conflicted-file>
git rebase --continue

# If it's genuinely too tangled:
git rebase --abort   # back to safety, figure out the right approach before retrying
```

For complex conflicts mid-stack, it can help to rebase one branch at a time and verify each compiles/tests before moving to the next child.

---

## Landing with `--onto` (squash-merge stacks)

When `main` uses **squash merges**, a plain `git rebase main` after landing the
bottom PR will replay all of its original commits as conflicts — because those
commits exist in the child branch's history but have been squashed away on `main`.

Use `--onto` instead:

```bash
# After PR 1 is squash-merged into main:
git rebase --onto main <old-base-sha> feature/auth-ui
git push --force-with-lease
```

Where `<old-base-sha>` is the commit that `feature/auth-ui` was originally
branched from (i.e. the tip of `feature/auth-base` before it was merged). This
replays only the commits that are *unique* to `feature/auth-ui`, skipping
everything that was already squashed into `main`.

Resolve any conflict once, `git rebase --continue`, then repeat up the stack.
If a rebase gets stuck, `git rebase --abort` and figure out the right base SHA
before retrying — do not force a resolution.

---

## Quick Reference

| Situation | Action |
|---|---|
| Creating a new slice | Branch off the top of the stack, PR targets parent branch |
| `main` got new commits | Rebase bottom-up through the entire stack |
| Review fixes a middle branch | Fix there, cascade rebase through all children |
| Bottom PR merges (merge commit) | Retarget next PR to `main`, rebase locally, push |
| Bottom PR merges (squash) | Use `git rebase --onto main <old-base-sha> <branch>` |
| Conflict during rebase | Fix file, `git add`, `git rebase --continue` |
| Force push | Always `--force-with-lease`, never `--force` |

---

## Code Comments

The codebase has three audiences for documentation: **contributors reading the code**, **Xcode Quick Help**, and **a future DocC site**. Three comment styles are in use — `///` doc comments, `//` inline remarks, and `// MARK:` section dividers — and this standard normalises their application across all layers of the codebase.

### Rule 1 — `///` on All Declarations

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
/// The search query entered by the user.
/// `nil` means no filter is active — all results are shown.
@State private var searchQuery: String?
```

### Rule 2 — Structured DocC Tags

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

### Rule 3 — Inline `//` Comments: Intent and Constraints Only

Plain `//` comments inside function bodies explain **decisions and constraints**, never restate what the code does. Issue and PR references (`// #560: Branch filter`) are encouraged and must be kept — they link runtime behaviour to the decision trail in git.

```swift
// ✅ Good — explains a non-obvious constraint
// Task.detached ensures the body runs off @MainActor so that
// urlSessionAPI's dispatchPrecondition(.notOnQueue(.main)) does not trap.

// ❌ Bad — restates the code
// Invalidate the timer
timer?.invalidate()
```

### Rule 4 — `// MARK:` Structure

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
// MARK: - Sub-view Helpers
```

Every `extension` in a separate file or at the bottom of a file gets its own `// MARK: -` divider. No `extension` block is left unmarked.

### Rule 5 — File Header

Every file begins with a minimal standard header. Issue history belongs in git log, not the file top. Multi-line issue-log blocks should be removed from file headers and replaced with a type-level `///` doc comment so they surface in Xcode Quick Help instead.

```swift
// ScopePreferencesStore.swift
// RunBotCore
//
// Persists per-scope user preferences (alias, polling interval, notifications)
// as a single Codable blob in UserDefaults.
// See: ScopePreferencesStoreProtocol, WorkflowScope, ScopeEditSheet
```

The `See:` line lists the primary collaborators so a new contributor knows where to look next without reading the full file.

### Rule 6 — The Only Exception

`// swiftlint:disable` suppression lines are tool directives, not declarations. They do not get `///` comments — leave them exactly as-is.
