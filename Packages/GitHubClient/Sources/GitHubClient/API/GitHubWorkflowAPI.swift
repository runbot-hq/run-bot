// GitHubWorkflowAPI.swift
// GitHubClient

import Foundation

// MARK: - Models

/// A GitHub Actions workflow run as returned by the REST API.
public struct GitHubWorkflowRun: Decodable, Sendable {
    /// Unique numeric run ID assigned by GitHub.
    public let id: Int
    /// Display name of the workflow (may be `nil` for anonymous workflows).
    public let name: String?
    /// Raw status string from the API: `"queued"`, `"in_progress"`, or `"completed"`.
    public let status: String
    /// Raw conclusion string: `"success"`, `"failure"`, `"cancelled"`, or `nil` when still running.
    public let conclusion: String?
    /// The branch this run was triggered on.
    public let headBranch: String?
    /// The commit SHA this run was triggered on.
    public let headSha: String
    /// GitHub web URL for this run.
    public let htmlUrl: String
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let createdAt: String
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let updatedAt: String

    /// Coding keys mapping snake_case JSON fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps `id`.
        case id
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `head_branch`.
        case headBranch = "head_branch"
        /// Maps `head_sha`.
        case headSha = "head_sha"
        /// Maps `html_url`.
        case htmlUrl = "html_url"
        /// Maps `created_at`.
        case createdAt = "created_at"
        /// Maps `updated_at`.
        case updatedAt = "updated_at"
    }
}

/// A GitHub Actions job as returned by the REST API.
///
/// ## let vs var field split
///
/// Fields are split into identity fields (`let`) and lifecycle fields (`var`):
///
/// - **`let` (identity):** `id`, `runID`, `name`, `status`, `htmlUrl`, `createdAt` —
///   assigned once by the GitHub API and never change for the lifetime of a job.
///   Mutating these would produce a logically different job, not an updated view
///   of the same one. `status` is intentionally `let`; it is a classification field
///   not patched locally — re-decode from the API when a status change is expected.
///   `createdAt` is `let` because job creation time is immutable; it is optional
///   only because some API responses omit it for in-flight jobs, not because it
///   changes after first appearance.
///
/// - **`var` (lifecycle):** `conclusion`, `runnerName`, `startedAt`, `completedAt`,
///   `steps` — populated progressively as the job runs and patched locally via
///   `copying(update:)` between polls.
///
/// ## Sendable
///
/// `var` fields on a value-type (`struct`) are safe for `Sendable` without `@unchecked`.
/// Each copy of the struct is independent — no shared mutable state exists.
public struct GitHubJob: Decodable, Identifiable, Equatable, Sendable {
    /// Unique numeric job ID assigned by GitHub.
    public let id: Int
    /// The workflow run this job belongs to. Maps the `run_id` JSON field.
    public let runID: Int
    /// Display name of the job.
    public let name: String
    /// Raw status string — NOT `JobStatus` (a RunBotCore type).
    ///
    /// Intentionally `let` — status is an identity/classification field set at job
    /// creation and never patched locally. It is not mutable via `copying(update:)`.
    /// Re-decode from the API when a status change is expected.
    public let status: String
    /// Raw conclusion string — NOT `JobConclusion` (a RunBotCore type).
    /// `var` — populated when the job completes; patched locally before next poll.
    public var conclusion: String?
    /// GitHub web URL for this job.
    /// Intentionally `let` — the URL is stable for the lifetime of the job.
    public let htmlUrl: String?
    /// Name of the runner executing this job, or `nil` if not yet assigned.
    /// `var` — assigned when a runner picks up the job; patched via `copying(update:)`.
    public var runnerName: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    /// `var` — set when the job starts; may arrive in a later poll than the initial decode.
    public var startedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    /// `var` — set when the job finishes; absent until completion.
    public var completedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    ///
    /// Intentionally `let` — job creation time is immutable; the field is optional
    /// only because some API responses omit it for in-flight jobs, not because it
    /// changes after first appearance. It is not a candidate for `copying(update:)`.
    public let createdAt: String?
    /// Steps within this job.
    /// `var` — replaced wholesale when step data arrives; absent for queued jobs (see decoder note).
    public var steps: [GitHubStep]

    /// Coding keys mapping snake_case JSON fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps `id`.
        case id
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `steps`.
        case steps
        /// Maps `run_id`.
        case runID = "run_id"
        /// Maps `html_url`.
        case htmlUrl = "html_url"
        /// Maps `runner_name`.
        case runnerName = "runner_name"
        /// Maps `started_at`.
        case startedAt = "started_at"
        /// Maps `completed_at`.
        case completedAt = "completed_at"
        /// Maps `created_at`.
        case createdAt = "created_at"
    }

    /// Decodes a `GitHubJob` from the GitHub REST API JSON payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        runID = try container.decode(Int.self, forKey: .runID)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
        htmlUrl = try container.decodeIfPresent(String.self, forKey: .htmlUrl)
        runnerName = try container.decodeIfPresent(String.self, forKey: .runnerName)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        // `try?` here is intentional, not a silent-failure smell.
        // The GitHub API omits the `steps` key entirely for queued jobs — it is
        // not an empty array but an absent key. `decodeIfPresent` returns `nil`
        // for an absent key, and `try?` converts a malformed-but-present array
        // to `nil` as well. Both cases correctly fall back to `[]`.
        // No logger call on the absent-key path: a missing `steps` key is the
        // documented API contract for queued jobs, not an error condition. A logger
        // call fires upstream in `fetchJobs` only when the entire `[GitHubJob]`
        // decode fails (a genuine API shape change). Not a decode bug.
        steps = (try? container.decodeIfPresent([GitHubStep].self, forKey: .steps)) ?? []
    }

    /// Full memberwise initialiser — used by `copying(update:)` and tests.
    public init(
        id: Int,
        runID: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        htmlUrl: String? = nil,
        runnerName: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        createdAt: String? = nil,
        steps: [GitHubStep] = []
    ) {
        self.id = id
        self.runID = runID
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.htmlUrl = htmlUrl
        self.runnerName = runnerName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.steps = steps
    }

    // MARK: - copying helper

    /// Returns a copy of this job with one or more lifecycle fields replaced.
    ///
    /// Only `var` fields (`conclusion`, `runnerName`, `startedAt`, `completedAt`,
    /// `steps`) can be mutated via the closure. Identity fields (`id`, `runID`,
    /// `name`, `status`, `htmlUrl`, `createdAt`) are `let` and the compiler will
    /// reject any attempt to assign them — this is intentional.
    ///
    /// `@discardableResult` is deliberately absent. Discarding the return value
    /// of a `copying` call is always a caller bug (the original is unchanged),
    /// so the compiler warning is the correct behaviour.
    ///
    /// This method is intentionally concrete on `GitHubJob` rather than extracted
    /// to a `Copyable` protocol. Protocol extraction is tracked in #67 and will
    /// be done once the pattern proves useful on additional model types.
    ///
    /// ```swift
    /// let updated = job.copying { $0.runnerName = "runner-1" }
    /// let multi   = job.copying { $0.conclusion = "success"; $0.runnerName = "runner-2" }
    /// ```
    public func copying(update: (inout Self) -> Void) -> Self {
        var copy = self
        update(&copy)
        return copy
    }
}

/// A single step within a GitHub Actions job.
public struct GitHubStep: Decodable, Equatable, Sendable {
    /// Display name of the step.
    public let name: String
    /// Raw status string from the API.
    public let status: String
    /// Raw conclusion string from the API, or `nil` if still running.
    public let conclusion: String?
    /// 1-based step number within the job.
    public let number: Int
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let startedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let completedAt: String?

    /// Coding keys mapping snake_case JSON fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `number`.
        case number
        /// Maps `started_at`.
        case startedAt = "started_at"
        /// Maps `completed_at`.
        case completedAt = "completed_at"
    }

    /// Memberwise initialiser for use within `GitHubClient` only.
    ///
    /// Intentionally `internal` — `GitHubStep` is `Decodable`-only at the public
    /// API surface. Tests construct instances via the JSON round-trip shim in
    /// `TestModelHelpers.swift` (`@testable import GitHubClient`).
    ///
    /// All fields are `let` by design — individual step mutation is not needed.
    /// Steps are replaced wholesale on `GitHubJob` via `job.copying { $0.steps = newSteps }`.
    /// If per-step patching is ever required, promote the relevant fields to `var`
    /// and add `Copyable` conformance (see #67).
    init(
        number: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil
    ) {
        self.number = number
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// The result of fetching active workflow runs, distinguishing auth/rate-limit failures
/// from partial and full successes.
///
/// - Note: `.authFailure` is currently never produced by `fetchActiveRuns` — the
///   underlying transport collapses all failure modes to `nil`, so auth failures
///   are surfaced as `.noToken` (first page) or `.rateLimited` (subsequent pages).
///   The case is part of the intended API for when the transport exposes a typed
///   `ExecuteResult`-returning call (tracked in #1950). Callers should handle it
///   defensively but must not rely on it being produced today.
public enum GitHubRunsFetchResult: Sendable {
    /// All pages fetched successfully.
    case success([GitHubWorkflowRun])
    /// Rate limit hit mid-fetch — results are valid but may be incomplete.
    case rateLimited([GitHubWorkflowRun])
    /// Token was rejected (401/403 without rate-limit headers) — discard everything.
    /// Currently unreachable from `fetchActiveRuns`; see type-level note above.
    case authFailure
    /// No GitHub token is configured — or any first-page transport failure
    /// (see type-level note above).
    case noToken
}

// MARK: - API

/// Fetches active (queued + in_progress) workflow runs for a scope.
///
/// Each `transport.apiPaginated` call records its own hits in the transport layer
/// (one count per successful HTTP page). No manual `apiCallCounter.record()` is needed.
///
/// `apiPaginated` returns a flat JSON array encoded as `Data`. This function decodes
/// that directly as `[GitHubWorkflowRun]` — **not** via a `{"workflow_runs":[...]}` wrapper.
/// The GitHub REST API wraps runs in a `workflow_runs` key, but `apiPaginated` strips the
/// envelope and returns only the array items, so no wrapper is needed here.
///
/// - Note: **Nil-transport heuristic —** `transport.apiPaginated` collapses all
///   failure modes (no token, rate limit, 401/403, network error) to `nil` because
///   the current transport API does not expose a typed result. The heuristic is:
///   nil on the **first** page (when `allRuns` is still empty) is surfaced as
///   `.noToken` to prompt sign-in; nil on a **subsequent** page is surfaced as
///   `.rateLimited` so callers keep the partial results. This means a rate-limit
///   hit on the first page is misclassified as `.noToken`, and a 401 mid-loop
///   is misclassified as `.rateLimited`. Both are known limitations tracked
///   in #1950 (typed `ExecuteResult` on the transport protocol).
///
/// - Important: **Call-counter budget —** the call counter fires inside the transport
///   layer on every successful HTTP response (2xx), not once per logical invocation
///   of this function. A fully successful call (both `in_progress` and `queued` pages
///   complete) registers **2** hits against the hourly budget. Early exits record only
///   the pages that completed: **0** hits on `.noToken`, **1** hit on `.rateLimited`.
///   Callers that display or gate on the counter value should account for this.
///
/// - Note: **Counter / result-count divergence on decode failure —** `callCounter.record()`
///   fires inside the transport on the HTTP hit, before this function decodes the body.
///   If `transport.decoder.decode([GitHubWorkflowRun].self, from: data)` throws, the
///   counter has already incremented but `allRuns` receives no new entries from that page.
///   The final `.success(allRuns)` may therefore contain fewer runs than
///   `counter.snapshot().count` implies. This is intentional and documented as non-fatal
///   (see the `catch` block below); callers must not treat the difference as a counter bug.
///
/// - Parameters:
///   - scope: The org or repo scope to query.
///   - transport: The network transport to use. Defaults to `currentTransport`
///     (wired at launch by `GitHubClient.init`). Pass a mock in tests.
@concurrent
public func fetchActiveRuns(
    scope: Scope,
    transport: any GitHubTransportProtocol = currentTransport
) async -> GitHubRunsFetchResult {
    let statuses = ["in_progress", "queued"]
    var allRuns: [GitHubWorkflowRun] = []
    var seenIDs = Set<Int>()
    for status in statuses {
        let endpoint = "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=\(GitHubConstants.activeRunsPageSize)"
        guard let data = await transport.apiPaginated(endpoint) else {
            if allRuns.isEmpty { return .noToken } else { return .rateLimited(allRuns) }
        }
        do {
            let runs = try transport.decoder.decode([GitHubWorkflowRun].self, from: data)
            for run in runs where seenIDs.insert(run.id).inserted {
                allRuns.append(run)
            }
        } catch {
            // Decode failure on a successful 2xx page is intentionally non-fatal.
            // The HTTP request succeeded — this is an API shape change or decoder
            // misconfiguration, not a network or auth condition. The loop continues
            // so a decode failure on one status page does not discard runs from the other.
            // callCounter.record() already fired in the transport layer for this hit,
            // so counter.snapshot().count may exceed allRuns.count — expected, not a bug.
            transport.logger?.log(
                "fetchActiveRuns › decode failed for status=\(status): \(error)",
                category: "transport"
            )
        }
    }
    return .success(allRuns)
}

/// Fetches all jobs for a given workflow run ID.
///
/// Each `transport.apiPaginated` call records its own hits in the transport layer
/// (one count per successful HTTP page). No manual `apiCallCounter.record()` is needed.
///
/// `apiPaginated` returns a flat JSON array encoded as `Data`. This function decodes
/// that directly as `[GitHubJob]` — **not** via a `{"jobs":[...]}` wrapper.
/// The GitHub REST API wraps jobs in a `jobs` key, but `apiPaginated` strips the
/// envelope and returns only the array items, so no wrapper is needed here.
///
/// - Parameters:
///   - runID: The numeric GitHub workflow run ID.
///   - scope: The org or repo scope the run belongs to.
///   - transport: The network transport to use. Defaults to `currentTransport`
///     (wired at launch by `GitHubClient.init`). Pass a mock in tests.
@concurrent
public func fetchJobs(
    runID: Int,
    scope: Scope,
    transport: any GitHubTransportProtocol = currentTransport
) async -> [GitHubJob] {
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)"
    guard let data = await transport.apiPaginated(endpoint) else { return [] }
    do {
        return try transport.decoder.decode([GitHubJob].self, from: data)
    } catch {
        transport.logger?.log(
            "fetchJobs › decode failed for runID=\(runID): \(error)",
            category: "transport"
        )
        return []
    }
}
