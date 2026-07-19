// RunnerPollerProtocol.swift
// RunBotCore

// MARK: - RunnerPollerProtocol

/// Minimal interface for the GitHub poll-loop actor.
///
/// Typed as `any RunnerPollerProtocol` in `AppState` so tests and SwiftUI
/// previews can substitute a `MockPoller` without importing the RunBot app target.
public protocol RunnerPollerProtocol: AnyObject {
    /// Starts (or restarts) the poll loop, observers, and initial fetch.
    func start() async
    /// Cancels all running Tasks owned by this poller.
    ///
    /// Declared `nonisolated` so callers on any actor (including `@MainActor`
    /// `AppState.stop()`) can invoke this without `await`. Implementations must
    /// only call thread-safe methods — e.g. `Task.cancel()` — from this context.
    ///
    /// Called from `AppState.stop()` on termination (#2153) so the poll loop
    /// drains before the process exits. Safe to call multiple times — cancelling
    /// an already-cancelled `Task` is a no-op in Swift Concurrency.
    nonisolated func cancel()
    /// The observable state object driven by this poller.
    ///
    /// Exposed on the protocol so callers holding `any RunnerPollerProtocol` —
    /// including `AppState` and SwiftUI preview hosts — can inject `state`
    /// into the environment without importing the concrete type.
    var state: RunnerState { get }
}

// MARK: - Conformance

/// `RunnerPoller` satisfies `RunnerPollerProtocol`. The `cancel()` implementation
/// lives in `RunnerPoller.swift` (not here) so it can access the `private`
/// `pollLoop` property.
extension RunnerPoller: RunnerPollerProtocol {}

// MARK: - MockPoller

// Placed in RunBotCore (not the test target) so SwiftUI previews — which run
// in the app process and cannot use @testable imports — can access MockPoller.
// If you no longer need it in previews, move it to TestDoubles.swift instead.

/// No-op actor that satisfies `RunnerPollerProtocol` for SwiftUI previews and
/// snapshot tests that must not trigger any network activity.
///
/// **Usage in previews**
/// ```swift
/// let state = RunnerState()
/// state.runners = Runner.previews          // pre-populate with fixture data
/// state.jobs    = ActiveJob.previews
/// state.actions = WorkflowActionGroup.previews
/// let mock = MockPoller(state: state)
/// MyView()
///     .environment(state)
/// ```
///
/// **Usage in tests**
/// Inject `MockPoller` wherever `any RunnerPollerProtocol` is expected.
/// Call `start()` or `cancel()` freely — both are guaranteed no-ops.
///
/// > Note: `init` is `@MainActor`-isolated because `RunnerState` is an
/// > `@MainActor` class. In a plain `async` test function (which is not
/// > `@MainActor` by default) construct via
/// > `await MainActor.run { MockPoller() }`, or annotate the test `@MainActor`.
public actor MockPoller: RunnerPollerProtocol {
    /// The observable state object this mock was initialised with.
    /// Callers may pre-populate it before passing it into the view or test subject.
    public let state: RunnerState

    /// Creates a `MockPoller` backed by the given `RunnerState`.
    ///
    /// - Parameter state: The observable state object to expose. Defaults to an
    ///   empty `RunnerState()` so callers that don't need pre-populated data can
    ///   omit the argument.
    @MainActor public init(state: RunnerState = RunnerState()) {
        self.state = state
    }

    /// No-op. Does not start a poll loop or make any network calls.
    public func start() async {}

    /// No-op. No tasks to cancel on a mock.
    public nonisolated func cancel() {}
}
