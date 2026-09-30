#!/usr/bin/env python3
"""Fail when a code comment references a `BacktickedType` that no longer exists.

Comments rot silently. A rename or deletion updates every call site — the compiler
insists — but leaves the prose pointing at a symbol nobody can find. The AppShell
migration left 69 such references across 38 files (#3029), including several
"DO NOT REMOVE" regression guards that named deleted types. A guard whose stated
reason is falsifiable is worse than no guard at all, because the next reader checks
the claim, finds nothing, and discounts the whole block.

Scope, and the limits that keep it quiet enough to leave on:

  * Only CamelCase identifiers inside `backticks`, and only in comment lines.
    Lowercase members and bare prose nouns are too noisy to be worth flagging.
  * A reference is skipped when its *comment block* frames it as history —
    "previously", "replaced by", "extracted from", "the popover-era", and friends.
    Writing down that something was deleted is good documentation, not rot, and the
    marker is usually on a neighbouring line of the same doc block, so whole
    contiguous blocks are evaluated together rather than line by line.
  * A name is satisfied by any declaration or filename under Sources/, Tests/, or
    the in-repo Packages/. Resolved dependency checkouts are deliberately excluded
    so the result does not depend on build state.
  * Anything left needs an entry in comment-symbols-allowlist.txt, which is for
    names owned outside this repository: Apple frameworks, POSIX signals, launchd
    plist keys, SonarCloud rules, the C# runner server.

Usage: python3 scripts/check-comment-symbols.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "comment-symbols-allowlist.txt"

HISTORICAL = re.compile(
    r"previous|legacy|removed|replaces|replaced|deleted|superseded|obsolete"
    r"|pre-|pre\-|popover-era|main-branch|extracted from|used to|no longer"
    r"|since removed|former|original|old |older |has been|migration|gone",
    re.IGNORECASE,
)
BACKTICKED = re.compile(r"`([A-Z][A-Za-z0-9_]*)`")
COMMENT = re.compile(r"^\s*(///|//)")


def search_roots():
    """Sources, Tests, and the in-repo Packages/ only.

    Deliberately excludes .build/checkouts: whether resolved dependencies are on
    disk depends on build order, so including them makes the result differ between
    a warm working copy and a clean CI checkout. Symbols owned by a *remote*
    dependency belong in the allowlist instead.
    """
    roots = [ROOT / "Sources", ROOT / "Tests", ROOT / "Packages"]
    return [r for r in roots if r.is_dir()]


def build_corpus(roots):
    """Every name that counts as existing: declarations plus file basenames."""
    code, filenames = [], set()
    for root in roots:
        for path in root.rglob("*.swift"):
            filenames.add(path.stem)
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
            code.extend(l for l in text.splitlines() if not COMMENT.match(l))
    return set(re.findall(r"\b[A-Z][A-Za-z0-9_]*\b", "\n".join(code))) | filenames


def comment_blocks(path):
    """Yield (start_line, [lines]) for each run of contiguous comment lines."""
    lines = path.read_text(errors="replace").splitlines()
    block, start = [], 0
    for i, line in enumerate(lines, 1):
        if COMMENT.match(line):
            if not block:
                start = i
            block.append((i, line))
        elif block:
            yield start, block
            block = []
    if block:
        yield start, block


def main():
    allow = set()
    if ALLOWLIST.exists():
        allow = {
            l.strip()
            for l in ALLOWLIST.read_text().splitlines()
            if l.strip() and not l.startswith("#")
        }

    known = build_corpus(search_roots())
    offenders = {}

    for target in ("Sources", "Tests"):
        for path in (ROOT / target).rglob("*.swift"):
            for _, block in comment_blocks(path):
                if HISTORICAL.search(" ".join(l for _, l in block)):
                    continue
                for lineno, line in block:
                    for name in BACKTICKED.findall(line):
                        if name in allow or name in known:
                            continue
                        rel = path.relative_to(ROOT)
                        offenders.setdefault(name, []).append(
                            f"{rel}:{lineno}: {line.strip()[:110]}"
                        )

    if not offenders:
        print(f"ok: no comment references unknown symbols ({len(known)} known names)")
        return 0

    print("error: comments reference symbols that do not exist:\n")
    for name in sorted(offenders):
        print(f"  {name}")
        for hit in offenders[name][:4]:
            print(f"      {hit}")
    print(
        "\nFix the reference, phrase it as history (\"replaced by …\"), or — only for\n"
        f"names owned outside this repo — add it to {ALLOWLIST.relative_to(ROOT)}."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
