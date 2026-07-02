# AppUpdater — Design Principles

These principles govern this library and all future changes to it. They are not negotiable.

**1. One enum owns all state.**
There is one `UpdatePhase` enum. All state is expressed as a case of that enum. There are no boolean flags, no parallel URL properties, no implicit combinations. Illegal states are unrepresentable by construction.

**2. No mid-flight recovery. Binary outcomes only.**
An update either succeeds or it doesn't. An app is either installable or it isn't. There is no partial-success path, no `open -n` failure recovery, no rehydration-on-launch. If something goes wrong mid-flow, the phase becomes `.failed`. The user relaunches or retries. We do not attempt to recover state across process boundaries.

**3. The task is exactly: check → download → verify → cache → install.**
Nothing else. This is the entire feature surface. Any requirement that adds a step outside this pipeline is out of scope.

**4. No sprawl.**
Do not add features to handle edge cases that arise from other features. If an edge case requires new state, new flags, or new recovery paths — the correct response is to remove the feature that created the edge case, not to add more code around it.

**5. Strict feature plane. Unsupported is correct.**
Not supporting every scenario is a feature, not a gap. A smaller, correct update flow is better than a large one with subtle state bugs that can leave users with a bricked app. When in doubt, do less.

**6. The library owns the flow, not the host.**
`AppUpdater` drives all phase transitions. The host only calls `apply()` — it never constructs or transitions phases itself. The seam is one-directional: library writes, host reads.

**7. No UserDefaults as state.**
UserDefaults is persistence, not state. The source of truth is the enum. The rehydration complexity deleted in this refactor came entirely from treating UserDefaults as a second state store.
