// ScopeStoreProtocol.swift
// RunBotCore

import Foundation

/// Protocol that abstracts the active-scopes store, allowing test doubles
/// to be injected into `RunnerPoller` without going through the live singleton.
///
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures without triggering
/// Swift 6's non-Sendable-type-exits-actor-isolated-context error.
///
/// - Note: Test doubles that implement this protocol with mutable state (e.g.
///   `var activeScopes: [String]`) must declare `@unchecked Sendable` to satisfy
///   the compiler under `-strict-concurrency=complete`. The `@MainActor`
///   isolation on the protocol guarantees all access happens on the main actor,
///   making `@unchecked` safe in practice for simple fake classes.
///
/// - Important: Conforming types **must** be `@Observable`. `RunnerPoller` wires
///   change notifications via `withObservationTracking`, which only fires its
///   `onChange` callback for properties accessed on concrete `@Observable` types.
///   A plain class conformance compiles correctly but the `onChange` closure will
///   never fire, so the poll loop will silently not restart when `activeScopes`
///   changes. Annotate all test doubles with `@Observable` to preserve production
///   behaviour.
@MainActor
public protocol ScopeStoreProtocol: AnyObject, Sendable {
    /// The list of scope identifiers (org or repo slugs) currently active.
    var activeScopes: [String] { get }
    /// All scope entries (including disabled) — needed for views that display
    /// or search the full list regardless of enabled state.
    var entries: [ScopeEntry] { get }
}

// MARK: - Production conformance
//
// Moved from RunnerPollerConformances.swift (#1618).
// Both the concrete type and the protocol are Core-resident; the conformance belongs here.

/// Conforms `ScopeStore` to `ScopeStoreProtocol` so the live singleton can be
/// injected at the production call site without any wrapper.
extension ScopeStore: ScopeStoreProtocol {}
