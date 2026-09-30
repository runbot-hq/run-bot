// WorkflowRunRef.swift
// RunBotCore

/// Lightweight reference to a single workflow run inside a `WorkflowActionGroup`.
///
/// Holds only the data needed for display and job fetching — deliberately
/// minimal so the full job list lives on the parent `WorkflowActionGroup` instead.
public struct WorkflowRunRef: Identifiable, Equatable, Sendable {
    /// The unique GitHub run ID.
    public let id: Int
    /// Workflow file name, e.g. `"SonarQube"`, `"vitest"`.
    public let name: String
    /// Current run status as a typed `JobStatus` value.
    public let status: JobStatus
    /// Run conclusion once completed, or `nil` while running.
    public let conclusion: JobConclusion?
    /// URL to the run detail page on github.com.
    public let htmlUrl: String?
    /// The attempt number of this run. Starts at 1; incremented on each rerun.
    public let runAttempt: Int

    /// Creates a new `WorkflowRunRef`.
    /// - Parameters:
    ///   - id: The unique GitHub run ID.
    ///   - name: Workflow file name.
    ///   - status: Current run status.
    ///   - conclusion: Run conclusion, or `nil` while running.
    ///   - htmlUrl: URL to the run detail page.
    ///   - runAttempt: Attempt number. Defaults to `1` so existing call sites compile unchanged.
    public init(id: Int, name: String, status: JobStatus, conclusion: JobConclusion?, htmlUrl: String?, runAttempt: Int = 1) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.htmlUrl = htmlUrl
        self.runAttempt = runAttempt
    }
}
