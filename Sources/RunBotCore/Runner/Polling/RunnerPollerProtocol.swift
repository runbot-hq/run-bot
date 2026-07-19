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
    /// Called from `AppState.stop()` on termination (#2153) so the poll loop
    /// is drained before the process exits. Safe to call multiple times —
    /// cancelling an already-cancelled `Task` is a no-op in Swift Concurrency.
    func cancel()
    /// The observable state object driven by this poller.
    ///
    /// Exposed on the protocol so callers holding `any RunnerPollerProtocol` —
    /// including `AppState` and SwiftUI preview hosts — can inject `state`
    /// into the environment without importing the concrete type.
    var state: RunnerState { get }
}

// MARK: - Conformance

/// `RunnerPoller` is the production implementation of `RunnerPollerProtocol`.
extension RunnerPoller: RunnerPollerProtocol {
    /// Cancels all poll-loop and scope-observation tasks.
    /// Delegates to `PollLoopCoordinator.cancelAll()` — same path as `isolated deinit`.
    public func cancel() {
        pollLoop.cancelAll()
    }
}

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
/// Call `start()` freely — it is a guaranteed no-op and never starts a Task.
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
    /// No-op. No tasks to cancel.
    public func cancel() {}
}
