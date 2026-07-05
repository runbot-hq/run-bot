# RunBot — Technical Principles

Engineering and design principles that govern the RunBot codebase.
Intended as a living reference for contributors and reviewers.

---

## Principles

The codebase adheres to these principles consistently. Do not introduce code that violates them without a documented reason.

### 1. Swift 6.2 + SwiftUI with Actor-Based Architecture

RunBot is built entirely in Swift 6.2 using SwiftUI, with a modern actor-based architecture that keeps all UI state on the `MainActor` and background work fully isolated in dedicated actors. This makes the concurrency model explicit, auditable, and enforced at compile time — not a convention that relies on developer discipline at runtime.

### 2. Async/Await and @Observable for Data Flow

Data flow is driven by Swift’s native `async`/`await` and `@Observable`, giving SwiftUI precise, fine-grained updates with minimal overhead. `@Observable` replaces the older `ObservableObject` + `@Published` pattern, removing the need for manual `objectWillChange` calls and reducing spurious view re-renders.

### 3. Typed Codable Models for Persisted Configuration

Persisted configuration is handled through typed `Codable` models rather than raw dictionaries or `UserDefaults` string keys. This means the compiler validates the shape of all serialised data and decoding failures surface as structured errors — not silent `nil` values or runtime crashes.

### 4. Compiler-Enforced Concurrency Boundaries

The compiler enforces all concurrency boundaries throughout the codebase. There are no `@unchecked Sendable` escape hatches in production types; every actor crossing is visible at the call site. This makes data-race safety a build-time guarantee rather than a testing-time hope.

### 5. macOS 26 Tahoe Liquid Glass Aesthetic

The visual design embraces the macOS 26 Tahoe Liquid Glass aesthetic, so RunBot feels like a natural extension of the OS. UI components are built to match the translucency, material hierarchy, and motion vocabulary introduced in macOS 26, rather than layering a custom design language on top.

→ [Liquid Glass implementation notes](https://gist.github.com/eonist/a8f0d160c7e9e37f634a15c3a33a8109)

### 6. Strict Value Semantics and Immutable Models

`RunnerModel` and related domain types are fully immutable structs — every property is `let`, and `Sendable` conformance is synthesised by the compiler without any `@unchecked` escape hatch. Mutations produce new values through a `copying(…)` method that uses the double-optional `Optional<Optional<T>>` pattern to distinguish “set to nil” from “leave unchanged”. This eliminates shared-mutable-state data races by construction rather than by convention.

### 7. Protocol-Oriented Dependency Injection

Concrete types are never referenced directly across module boundaries where testability matters. Instead, `protocol`-typed dependencies (`RunnerConfigStoreProtocol`, `RunnerProxyStoreProtocol`, `RunnerLabelsService`) are injected at construction time. This makes every use-case fully testable in isolation with real implementations in production and lightweight fakes in tests — no method-swizzling or singleton-patching required.

### 8. Use-Case Pattern (Clean Architecture)

Business logic is encapsulated in dedicated `Sendable` use-case structs (e.g. `SaveRunnerEditsUseCase`). Each use-case exposes a single `execute()` method, takes all dependencies via constructor injection, and owns no mutable state. This keeps business logic independently testable and prevents it from accumulating in view models or the app delegate.

### 9. Structured Concurrency for Stateful Timers

Polling timers are implemented as structured `Task` trees using `AsyncStream` or actor-serialised `for await` loops rather than `Timer`/`DispatchSourceTimer`. The task is cancelled on teardown, giving automatic cleanup with no reference cycles or runloop coupling. Timer state lives on the owning actor, not in a shared global.

### 10. Atomic Snapshot Pattern (Eliminating TOCTOU Races)

Anywhere a decision is made on a value that could change between read and use, the value is captured into a local `let` binding before the first conditional check. No property is read twice in a decision path. This eliminates time-of-check/time-of-use races without requiring locks.

### 11. Module-Level Transport Shim and URLSession Async

All network I/O goes through a module-level `transport` shim (`(URLRequest) async throws -> (Data, URLResponse)`). In production this wraps `URLSession.data(for:)`. In tests it is replaced with a closure that returns fixture data synchronously. No `URLSession` subclassing, no `URLProtocol` registration, no global state.

### 12. Link-Header Pagination

Paginated GitHub API endpoints are consumed by following `Link: <url>; rel="next"` headers automatically, accumulating items across all pages into a single flat result. Mid-pagination authentication failures discard all partial results and return `nil` — because partial data from a broken auth session is worse than no data. Rate-limit hits during pagination return the partial results collected so far, since those items are valid and the rate-limit will clear. This distinction is deliberate and explicitly documented.

### 13. Multi-Target Swift Package with Testable Core

The project is structured as a pure Swift Package Manager project (`swift-tools-version: 6.2`) with a `RunBotCore` library target fully decoupled from the `RunBot` executable target, plus a dedicated `RunBotCoreTests` test target. The entire domain and networking layer can be unit-tested without instantiating any UI or app infrastructure, and the library/executable boundary is enforced by the package manifest — not just by convention.

### 14. XcodeGen for Reproducible Xcode Projects

Rather than committing the `.xcodeproj` bundle, the project uses XcodeGen (`project.yml`) to generate it deterministically from a human-readable specification. This eliminates merge conflicts in Xcode project files, keeps the repository diff-friendly, and ensures that the project file is always consistent with the source layout — it cannot drift independently.

### 15. Static Code Quality Pipeline

Dead-code elimination, style enforcement, and continuous quality analysis are all automated at CI time:

- **Periphery** (`.periphery.yml`) — detects unused types, functions, and properties at the compiler-graph level, not just by text search.
- **SwiftLint** (`.swiftlint.yml`) — enforces a project-specific style ruleset with custom rule configurations.
- **SonarCloud** (`sonar-project.properties`) — provides continuous quality gates, duplication analysis, and security scanning across every pull request.

### 16. Actor-Per-Concern Isolation

Each mutable domain owns its own dedicated actor: `RateLimitActor` serialises all rate-limit state, and `RunnerConfigStore` is itself an actor that serialises all disk I/O for runner configuration files. The principle is one actor per mutable concern, zero shared mutable state anywhere — not one global “background actor” that everything piles into.

### 17. nonisolated for Safe Cross-Boundary Capture

`JSONDecoder` instances are marked `nonisolated` on actors where they need to be captured inside closures or called from `@concurrent` free functions that cross isolation boundaries. This is a deliberate, compiler-enforced acknowledgment that `JSONDecoder` has no mutable state after initialisation and is therefore safe to use across actor boundaries without synchronisation.

### 18. @concurrent for Blocking I/O

Synchronous disk I/O is kept off actor cooperative threads using `@concurrent` async free functions. A function marked `@concurrent` runs on the Swift cooperative thread pool but is not bound to any actor’s serial executor, so a blocking `Data(contentsOf:)` or `Data.write(to:)` call inside it cannot stall the actor that called it.

`@concurrent` is an *isolation* solution, not a *non-blocking I/O* solution — a blocking call still occupies one cooperative thread pool worker for the duration of the I/O. For the low-frequency disk operations in this codebase this is an acceptable trade-off. This pattern replaces the legacy `withCheckedContinuation` / `DispatchQueue.global(qos: .utility)` bridge, which should not be introduced in new code.

### 19. AnyJSON Type-Erased Codec

Any API surface that must accept or return arbitrary JSON without a fixed schema uses the `AnyJSON` enum (`case string`, `case number`, `case bool`, `case array`, `case object`, `case null`) rather than `[String: Any]` dictionaries. `AnyJSON` is `Codable`, `Sendable`, `Equatable`, and `Hashable` — it participates in the type system instead of escaping it.

### 20. Typed Error Discrimination with ExecuteResult

Process execution results are returned as a typed `ExecuteResult` enum rather than a throwing function with a generic `Error`. The enum cases distinguish exit-code failures, timeout kills, and system-level launch errors at the type level, so callers are forced by the compiler to handle each case explicitly rather than catching a generic `Error` and pattern-matching strings.

### 21. Human-Readable Config Writes

Persisted `.runner` configuration files are written as pretty-printed JSON with sorted keys — not compact single-line blobs. This makes git diffs reviewable by humans, allows the graveyard doc to show before/after examples inline, and means that a manual config edit in a text editor produces a minimal diff on next save.

---

## Reach-Goal Principles

These are directions the codebase is moving toward. Apply them in new code where practical; stop short if the engineering cost is disproportionate to the change at hand. Principles here graduate to the section above once adopted consistently across the codebase.

### 1. Swift Testing

Swift Testing (shipped with Swift 6.0) replaces `XCTestCase` with macro-based `@Test` functions, `#expect` assertions, and `@Suite` groupings. Test structs receive a fresh instance per test with no shared state, which aligns directly with the value-semantics principle already adopted in the core library. Parameterised tests via `@Test(arguments:)` replace repetitive test methods.

**Target:** All new tests use Swift Testing (`@Test`, `#expect`, `@Suite`). `XCTestCase` is treated as legacy and migrated opportunistically.

### 2. Observations Async Sequence for State Streaming

Swift 6.2 adds `Observations<Value>` — an `AsyncSequence` that streams transactional snapshots of `@Observable` properties. Each emission represents a consistent state at an `await` boundary, not individual property mutations, so observers never see a half-updated model. This eliminates the need for manual `withObservationTracking` polling loops in non-SwiftUI consumers.

**Target:** Reactive state consumers outside of SwiftUI views use `Observations` async sequences rather than polling or manual `withObservationTracking` callbacks.

### 3. Access Control for Imports (internal import)

Swift 6.0 introduced `internal import` and `package import` as formal access control on import declarations. `RunBotCore` can explicitly prevent implementation-detail dependencies from leaking into its public API surface — enforced by the compiler, not by convention.

**Target:** All imports in `RunBotCore` are annotated with the minimum required access level. Public re-export of transitive dependencies is never implicit.

### 4. Typed Throws at Domain Boundaries

Typed throws (`throws(DomainError)`) matured across Swift 6.0–6.2. Use them at use-case and service layer boundaries where the error set is closed and stable; keep untyped `throws` at the transport layer where errors are structurally open.

**Target:** Use-case `execute()` methods throw a dedicated, closed error enum (e.g. `throws(RunnerEditError)`). Transport functions retain untyped `ExecuteResult` returns.

### 5. Isolated Synchronous deinit

Swift 6.2 adds `isolated deinit`, allowing actor-isolated cleanup code to run on the actor itself rather than on an arbitrary thread. Without this, actor deinit runs off-actor and resource teardown requires workarounds such as explicit `invalidate()` methods or detached cleanup tasks.

**Target:** Actors that own resources with teardown requirements (file handles, open network sessions, running `Task` trees) use `isolated deinit`. Explicit `invalidate()` patterns are a fallback, not the default.

### 6. Task Naming and Priority Escalation

Swift 6.2 introduced Task naming via `Task(name:)` and Task Priority Escalation APIs (SE-0462). Task names surface in Instruments and crash logs, making structured concurrency trees debuggable by name rather than by opaque memory address.

**Target:** All long-lived or structurally significant tasks are created with a descriptive `name:` parameter. Tasks that serve user-interactive paths are created at `.userInitiated` priority so escalation can propagate correctly.

### 7. @attached(body) Macros for Cross-Cutting Concerns

Swift 6.0 added `@attached(body)` macros that synthesise or augment function implementations. This makes it practical to attach cross-cutting behaviours — logging, timing, retry logic — to use-case `execute()` methods without subclassing or decorator boilerplate.

**Target:** Cross-cutting concerns on use-case boundaries are implemented as `@attached(body)` macros rather than manual decoration or base-class inheritance.

### 8. Typed Distributed Actors

Swift 6.0’s typed distributed actor system allows inter-process and inter-device actors to share the same protocol surface as local actors, with the network boundary enforced by the type system rather than by serialisation boilerplate. For a future multi-process RunBot (e.g. a privileged helper communicating with the UI process), distributed actors would eliminate the XPC glue layer entirely.

**Target:** Any future cross-process communication boundary uses typed distributed actors rather than raw XPC or mach ports.

### 9. Eager Move Optimisation for Hot Allocations

The `consume` operator (SE-0366, Swift 5.9+) forces the compiler to move a value rather than copy it, immediately ending the variable’s lifetime. For large value types on hot paths — e.g. `[WorkflowActionGroup]` arrays passed through the pipeline — this eliminates ARC traffic that would otherwise accumulate.

**Target:** Hot-path value-type pipelines use `consume` at ownership transfer points where profiling shows measurable ARC overhead.

### 10. Parameter Packs for Generic Pipelines

Swift 5.9’s parameter packs (SE-0393) allow a single generic function to operate over a statically typed, variadic list of types. This eliminates overload families (`process(_:)`, `process(_:_:)`, `process(_:_:_:)`) in favour of a single declaration.

**Target:** Overload families with identical logic across arities are replaced with a single parameter-pack generic.

### 11. Swift Macros for Protocol + Fake Generation

`@attached(peer)` and `@attached(conformance)` macros can auto-generate a protocol + test-double pair from a concrete type. Combined with principle 7 (Protocol-Oriented DI), this eliminates the manual maintenance of `*Protocol` files and their corresponding `Fake*` test doubles.

**Target:** Protocol + fake pairs for use-cases and services are generated by macro, not written by hand.

### 12. Regex Literals for Structured Parsing

Swift 5.7’s `Regex` literals and `RegexBuilder` DSL replace string-based regular expressions with compiler-checked, type-safe patterns. Capture groups produce named, typed values rather than `[String?]` arrays, and the pattern is validated at compile time.

**Target:** All regex-based parsing in `RunBotCore` uses `Regex` literals or `RegexBuilder`. String-based `NSRegularExpression` is treated as legacy.

### 13. #if canImport Guards for Cross-Platform Core

If `RunBotCore` ever needs to run on Linux (e.g. for a server-side runner management CLI), AppKit and Foundation APIs that are macOS-only must be wrapped in `#if canImport(AppKit)` guards. This is zero-cost on macOS but makes the boundary explicit and keeps the core compilable cross-platform without changes.

**Target:** Any AppKit import in `RunBotCore` is wrapped in `#if canImport(AppKit)`. New `RunBotCore` code avoids AppKit imports unless strictly necessary.

### 14. sending Parameters for Non-Sendable Cross-Isolation Transfer

Swift 6’s `sending` keyword (SE-0430) allows a non-`Sendable` value to cross an isolation boundary when the compiler can prove the caller’s region no longer holds a reference after the call. This is preferred over adding `@unchecked Sendable` to a type solely to enable the transfer.

**Target:** `sending` is used on function parameters where a non-`Sendable` value is intentionally transferred across an isolation boundary and the caller genuinely relinquishes access.

### 15. consuming / borrowing on Value-Type Pipelines

The domain types (`RunnerModel`, `RunnerConfig`, `RunnerProxyConfig`) are already immutable `let`-only structs. `consuming` on a method expresses “this instance is done after this call” — making it a compile error to reuse a value after finalisation. `borrowing` on a parameter eliminates hidden ARC copies on high-frequency read paths.

**Target:** `consuming` is applied to single-use finaliser methods where reuse after the call is a logic error. `borrowing` is applied to read-only parameters on hot-path functions where ARC copy elimination is measurable.
