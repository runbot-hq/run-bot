// RunnerViewModelProtocol.swift
// RunBotCore
import Foundation

// MARK: - RunnerViewModelProtocol

/// Push-receiver interface through which `LocalRunnerStore` delivers
/// its computed snapshots to the main-actor presentation layer.
///
/// The five GitHub API props (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`) moved to `RunnerState` in Step 3 and are no longer
/// part of this protocol (removed in Step 15).
///
/// Declaring the protocol in `RunBotCore` (rather than the app target) achieves two goals:
/// 1. `RunnerPoller` and `LocalRunnerStore` can reference it without importing AppKit or SwiftUI.
/// 2. Test doubles (`MockRunnerViewModel`) can be defined inside `RunBotCoreTests` and
///    passed into the actors without any app-target dependency.
///
/// **Direction of data flow:** stores *push* into the receiver; the receiver never pulls.
/// All mutations arrive on `@MainActor` via `await MainActor.run { }`.
///
/// ## Why `{ get set }` and not `{ get }`
/// `LocalRunnerStore` writes into both properties through the fully-erased
/// `any RunnerViewModelProtocol` existential. Swift only allows writes through an
/// existential when the protocol requirement is declared `{ get set }`.
/// The setter is therefore structurally required — it is the push mechanism itself.
///
/// ## Why `RunnerState` uses `public var` and not `public internal(set) var`
/// Swift requires the conforming property’s setter to be at least as accessible as
/// the protocol requirement. A `public internal(set)` setter is module-internal and
/// does not satisfy a `public` protocol’s `{ get set }` requirement at the module
/// interface — the compiler rejects it with
/// “setter for ‘localRunners’ must be declared public”.
/// Encapsulation is preserved by convention: only `LocalRunnerStore` (in `RunBotCore`)
/// writes these properties; external callers in `RunBot` read them via `@Observable`.
@MainActor
public protocol RunnerViewModelProtocol: AnyObject, Sendable {
    // MARK: Pushed by LocalRunnerStore

    /// Locally-installed runner agents discovered on this Mac.
    /// `{ get set }` is required — `LocalRunnerStore` writes via the existential.
    var localRunners: [RunnerModel] { get set }
    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    /// `{ get set }` is required — `LocalRunnerStore` writes via the existential.
    var isLocalScanning: Bool { get set }
}

// MARK: - RunnerState conformance

/// `RunnerState` satisfies `RunnerViewModelProtocol` with no additional implementation.
/// Both `localRunners` and `isLocalScanning` are declared `public var` — see the
/// protocol-level doc comment for the access-level rationale.
extension RunnerState: RunnerViewModelProtocol {}
