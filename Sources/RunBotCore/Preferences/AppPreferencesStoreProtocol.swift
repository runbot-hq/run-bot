// AppPreferencesStoreProtocol.swift
// RunBotCore

import Foundation

/// Protocol that abstracts app-level preferences, allowing test doubles
/// to be injected into `RunnerPoller` without going through the live singleton.
///
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures without triggering
/// Swift 6’s non-Sendable-type-exits-actor-isolated-context error.
///
/// - Note: Test doubles that implement this protocol must declare
///   `@unchecked Sendable` to satisfy the compiler under
///   `-strict-concurrency=complete`. The `@MainActor` isolation on the protocol
///   guarantees all access happens on the main actor, making `@unchecked` safe
///   in practice for simple fake classes.
///
/// - Important: Conforming types **must** be `@Observable`. `RunnerPoller` wires
///   change notifications via `withObservationTracking`, which only fires its
///   `onChange` callback for properties accessed on concrete `@Observable` types.
///   A plain class conformance compiles correctly but observation callbacks will
///   never fire. Annotate all test doubles with `@Observable` to preserve
///   production behaviour.
///
/// - Note: `pollingInterval` was removed from this protocol in Step 10 of #2069.
///   `RunnerPoller` no longer reads it — poll cadence is fully driven by
///   `PollIntervalStrategy`. The underlying `settings.pollingInterval` UserDefaults
///   key is retained in `AppPreferencesStore` for backward compatibility with
///   existing installs but is no longer surfaced anywhere in the app.
@MainActor
public protocol AppPreferencesStoreProtocol: AnyObject, Sendable {
}

// MARK: - Production conformance
//
// Moved from RunnerPollerConformances.swift (#1618).
// Both the concrete type and the protocol are Core-resident; the conformance belongs here.

/// Conforms `AppPreferencesStore` to `AppPreferencesStoreProtocol` so the live
/// singleton can be injected at the production call site without any wrapper.
extension AppPreferencesStore: AppPreferencesStoreProtocol {}
