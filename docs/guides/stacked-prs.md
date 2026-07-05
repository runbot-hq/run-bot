# Stacked PRs — Best Practices

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
