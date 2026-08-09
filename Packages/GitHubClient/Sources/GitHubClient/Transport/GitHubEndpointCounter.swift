// GitHubEndpointCounter.swift
// GitHubClient

import Foundation

// MARK: - GitHubEndpointKey

/// A normalised key for grouping HTTP responses by scope and endpoint category.
///
/// Both properties are derived from the request URL during `record()`:
/// - `scope` identifies the GitHub resource owner (e.g. `repo:owner/repo` or `org:acme`).
/// - `endpoint` identifies the API category (e.g. `runners`, `run_jobs`, `job_detail`).
internal struct GitHubEndpointKey: Hashable, Sendable {
    /// The resource-owner scope, normalised to a stable string.
    let scope: String
    /// The API endpoint category, normalised to a stable string.
    let endpoint: String
}

// MARK: - GitHubEndpointReport

/// A compact, deterministic diagnostic report of endpoint activity for a time window.
///
/// The report is formatted as one header line plus one line per scope/endpoint/status bucket.
///
/// ## Format
/// ```
/// GitHubEndpointCounter › 60s total=184
/// repo:eoncode/run-bot runners total=20 200=20
/// repo:eoncode/run-bot runs.in_progress total=20 200=2 304=18
/// ```
internal struct GitHubEndpointReport: Sendable {
    /// Total number of responses counted in this window.
    let total: Int
    /// The actual elapsed duration of this window (seconds, rounded to nearest integer).
    let durationSeconds: Int
    /// Per-bucket counts, where each bucket is a scope/endpoint pair with per-status counts.
    let buckets: [Bucket]

    /// A single scope/endpoint/status bucket.
    struct Bucket: Sendable {
        /// The normalised scope string.
        let scope: String
        /// The normalised endpoint string.
        let endpoint: String
        /// Per-status-code counts for this bucket, sorted by status code ascending.
        let statusCounts: [(status: Int, count: Int)]
    }

    /// Returns a deterministic string representation of this report.
    ///
    /// Buckets are sorted by scope (alphabetically), then by endpoint (alphabetically).
    /// Status codes within each bucket are sorted numerically.
    func formatted() -> String {
        var lines: [String] = []
        lines.append("GitHubEndpointCounter › \(durationSeconds)s total=\(total)")
        for bucket in buckets {
            let statusParts = bucket.statusCounts.map { "\($0.status)=\($0.count)" }.joined(separator: " ")
            let totalForBucket = bucket.statusCounts.reduce(0) { $0 + $1.count }
            lines.append("\(bucket.scope) \(bucket.endpoint) total=\(totalForBucket) \(statusParts)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - GitHubEndpointCounter

/// An internal actor that counts completed GitHub HTTP round trips by scope, endpoint
/// category, and HTTP status code.
///
/// Every 60-second window, the first `record()` call after the interval expires returns
/// a `GitHubEndpointReport` containing counts for the completed window. The caller
/// (typically `GitHubTransport`) is expected to log the report via `GitHubLogger`.
///
/// This design avoids a detached periodic task lifecycle: there is no background loop,
/// no cancellation-tracking, and no empty reports while idle.
///
/// ## Thread safety
/// `GitHubEndpointCounter` is an actor, so all mutable state is isolated to its own
/// serial executor.
///
/// ## Non-goals
/// - Does not modify `APICallCounterProtocol` or `APICallCounter`.
/// - Does not change request, cache, polling, or rate-limit behaviour.
/// - Measurement only — no side effects on requests.
internal actor GitHubEndpointCounter {

    /// Accumulated counts keyed by (scope, endpoint, statusCode).
    private var counts: [GitHubEndpointKey: [Int: Int]] = [:]

    /// The clock used for window timing.
    private let clock = ContinuousClock()

    /// The instant at which the current window started.
    private var windowStartedAt: ContinuousClock.Instant

    /// The duration of each reporting window.
    private let reportInterval: Duration

    /// Creates a new endpoint counter with the given reporting interval.
    ///
    /// - Parameter reportInterval: How often `record()` returns a report. Defaults to 60 seconds.
    init(reportInterval: Duration = .seconds(60)) {
        self.reportInterval = reportInterval
        self.windowStartedAt = ContinuousClock().now
    }

    /// Records one completed HTTP response and returns a report if the interval has expired.
    ///
    /// The URL is parsed to extract the scope and endpoint category. Dynamic IDs
    /// (run IDs, job IDs, attempt numbers) and pagination parameters are normalised
    /// so that they do not create additional keys. The `status` query parameter on
    /// `/actions/runs` list URLs is captured into a separate category so that
    /// `in_progress`, `queued`, and `completed` queries are distinguishable.
    ///
    /// - Parameters:
    ///   - url: The absolute URL of the completed request.
    ///   - statusCode: The HTTP status code of the response.
    /// - Returns: A report for the completed window, or `nil` if the window is still active.
    func record(url: String, statusCode: Int) -> GitHubEndpointReport? {
        let key = normalizeKey(from: url)
        let bucket = counts[key, default: [:]]
        counts[key] = bucket.merging([statusCode: 1], uniquingKeysWith: +)

        let now = clock.now
        guard now - windowStartedAt >= reportInterval else {
            return nil
        }

        let durationSeconds = Int(
            (now - windowStartedAt).components.seconds
        )
        let report = buildReport(durationSeconds: durationSeconds)
        counts.removeAll(keepingCapacity: true)
        windowStartedAt = now
        return report
    }

    // MARK: - Private helpers

    /// Builds a `GitHubEndpointReport` from the current accumulated counts.
    private func buildReport(durationSeconds: Int) -> GitHubEndpointReport {
        let total = counts.values.reduce(0) { sum, bucket in
            sum + bucket.values.reduce(0, +)
        }
        var buckets: [GitHubEndpointReport.Bucket] = []
        for (key, statusCounts) in counts {
            let sorted = statusCounts.sorted { $0.key < $1.key }
            buckets.append(GitHubEndpointReport.Bucket(
                scope: key.scope,
                endpoint: key.endpoint,
                statusCounts: sorted.map { (status: $0.key, count: $0.value) }
            ))
        }
        buckets.sort { lhs, rhs in
            if lhs.scope != rhs.scope { return lhs.scope < rhs.scope }
            return lhs.endpoint < rhs.endpoint
        }
        return GitHubEndpointReport(
            total: total,
            durationSeconds: durationSeconds,
            buckets: buckets
        )
    }

    /// Normalises a URL string to a `GitHubEndpointKey` by extracting the scope
    /// and endpoint category, stripping dynamic IDs and pagination parameters.
    ///
    /// - Parameter url: The absolute URL string to normalise.
    /// - Returns: A `GitHubEndpointKey` suitable for aggregation.
    private func normalizeKey(from url: String) -> GitHubEndpointKey {
        // Use URLComponents to preserve query items for status extraction.
        guard let components = URLComponents(string: url),
              let host = components.host else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let hostPlusPath = host + (components.path)

        let pathComponents = hostPlusPath
            .split(separator: "/")
            .map(String.init)

        guard let apiIndex = pathComponents.firstIndex(where: { $0 == "api.github.com" || $0.hasSuffix(".api.github.com") }) else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let afterAPI = pathComponents[(apiIndex + 1)...]
        let pathParts = Array(afterAPI)

        guard !pathParts.isEmpty else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let (scope, remaining): (String, [String]) = {
            switch pathParts[0] {
            case "repos":
                guard pathParts.count >= 3 else {
                    return ("global/other", Array(pathParts))
                }
                return ("repo:\(pathParts[1])/\(pathParts[2])", Array(pathParts.dropFirst(3)))
            case "orgs":
                guard pathParts.count >= 2 else {
                    return ("global/other", Array(pathParts))
                }
                return ("org:\(pathParts[1])", Array(pathParts.dropFirst(2)))
            case "user":
                return ("user", Array(pathParts.dropFirst(1)))
            default:
                return ("global/other", pathParts)
            }
        }()

        // Extract the status query parameter before normalising the endpoint.
        let statusQuery = components.queryItems?
            .first(where: { $0.name == "status" })?
            .value

        return GitHubEndpointKey(
            scope: scope,
            endpoint: normalizeEndpoint(remaining, statusQuery: statusQuery)
        )
    }

    /// Maps the remaining path components (after scope) to a stable endpoint category,
    /// incorporating the `status` query parameter for runs list URLs.
    ///
    /// - Parameters:
    ///   - components: The path components after the scope prefix.
    ///   - statusQuery: The value of the `status` query parameter, if present.
    /// - Returns: A normalised endpoint category string.
    private func normalizeEndpoint(_ components: [String], statusQuery: String?) -> String {
        // No components → unknown.
        guard !components.isEmpty else { return "global/other" }

        // Top-level: /actions/...
        guard components[0] == "actions" else {
            return "global/other"
        }

        let rest = Array(components.dropFirst())

        // /actions/runners
        if rest.first == "runners" {
            return "runners"
        }

        // /actions/runs/...
        if rest.first == "runs" {
            guard rest.count >= 2 else {
                // /actions/runs?status=... — list endpoint with query
                return categorizeRunsList(statusQuery: statusQuery)
            }
            _ = rest[1]
            let runSuffix = Array(rest.dropFirst(2))

            if runSuffix.isEmpty {
                return categorizeRunsList(statusQuery: statusQuery)
            }

            // /actions/runs/{run_id}/status
            if runSuffix.first == "status" {
                return "runs.all"
            }

            // /actions/runs/{run_id}/attempts/{attempt_num}/jobs
            if runSuffix.first == "attempts" {
                return "run_jobs_attempt"
            }

            // /actions/runs/{run_id}/jobs
            if runSuffix.first == "jobs" {
                return "run_jobs"
            }

            // /actions/runs/{run_id}/timing
            if runSuffix.first == "timing" {
                return "runs.all"
            }

            return "runs.all"
        }

        // /actions/jobs/...
        if rest.first == "jobs" {
            guard rest.count >= 2 else {
                return "global/other"
            }
            let jobSuffix = Array(rest.dropFirst(2))
            // /actions/jobs/{job_id}/logs
            if jobSuffix.first == "logs" {
                return "job_logs"
            }
            return "job_detail"
        }

        return "global/other"
    }

    /// Categorises a runs list endpoint based on the `status` query parameter.
    ///
    /// - Parameter statusQuery: The value of the `status` query parameter, or `nil`.
    /// - Returns: `runs.in_progress`, `runs.queued`, `runs.completed`, `runs.all`, or `runs.other`.
    private func categorizeRunsList(statusQuery: String?) -> String {
        switch statusQuery {
        case "in_progress":
            return "runs.in_progress"
        case "queued":
            return "runs.queued"
        case "completed":
            return "runs.completed"
        case nil:
            return "runs.all"
        default:
            return "runs.other"
        }
    }
}
