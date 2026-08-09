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
        lines.append("GitHubEndpointCounter › 60s total=\(total)")
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
/// Every 60-second window, a report is emitted through the existing `GitHubLogger`.
/// Counters reset after each report.
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

    /// Creates a new endpoint counter.
    init() {}

    /// Records one completed HTTP response.
    ///
    /// The URL is parsed to extract the scope and endpoint category. Dynamic IDs
    /// (run IDs, job IDs, attempt numbers) and pagination parameters are normalised
    /// so that they do not create additional keys.
    ///
    /// - Parameters:
    ///   - url: The absolute URL of the completed request.
    ///   - statusCode: The HTTP status code of the response.
    func record(url: String, statusCode: Int) {
        let key = normalizeKey(from: url)
        let bucket = counts[key, default: [:]]
        counts[key] = bucket.merging([statusCode: 1], uniquingKeysWith: +)
    }

    /// Returns a snapshot of the current counts **without** resetting counters.
    /// - Returns: A report of all accumulated counts.
    func snapshot() -> GitHubEndpointReport {
        buildReport()
    }

    /// Returns a report of the current counts and **resets all counters** for the next window.
    /// - Returns: A report of counts accumulated since the last report or creation.
    func report() -> GitHubEndpointReport {
        let report = buildReport()
        counts = [:]
        return report
    }

    /// Starts a periodic task that logs a report through the given logger every `interval`.
    ///
    /// - Parameters:
    ///   - logger: The logger to emit reports through.
    ///   - interval: How often to emit a report. Defaults to 60 seconds.
    /// - Returns: A `Task` that can be cancelled to stop periodic reporting.
    @discardableResult
    func startPeriodicReporting(logger: any GitHubLogger, interval: Duration = .seconds(60)) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    guard let self else { break }
                    let report = await self.report()
                    if report.total > 0 {
                        logger.log(report.formatted(), category: "transport")
                    }
                } catch {
                    break
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Builds a `GitHubEndpointReport` from the current accumulated counts.
    private func buildReport() -> GitHubEndpointReport {
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
        return GitHubEndpointReport(total: total, buckets: buckets)
    }

    /// Normalises a URL string into a `GitHubEndpointKey` by extracting the scope
    /// and endpoint category.
    ///
    /// Examples:
    /// - `https://api.github.com/repos/eoncode/run-bot/actions/runners` → `repo:eoncode/run-bot`, `runners`
    /// - `https://api.github.com/orgs/acme/actions/runners` → `org:acme`, `runners`
    /// - `https://api.github.com/repos/eoncode/run-bot/actions/runs/12345` → `repo:eoncode/run-bot`, `runs.all`
    /// - `https://api.github.com/repos/eoncode/run-bot/actions/runs/12345/jobs` → `repo:eoncode/run-bot`, `run_jobs`
    /// - `https://api.github.com/repos/eoncode/run-bot/actions/jobs/67890` → `repo:eoncode/run-bot`, `job_detail`
    /// - Unknown → `global/other`, `global/other`
    private func normalizeKey(from url: String) -> GitHubEndpointKey {
        // Strip query parameters for normalisation.
        let base = url.split(separator: "?").first.map(String.init) ?? url
        // Strip trailing slash.
        let cleaned = base.hasSuffix("/") ? String(base.dropLast()) : base
        let pathComponents = cleaned.split(separator: "/").map(String.init)

        // Find the scope prefix (repos, orgs, user).
        // Expected structure: scheme/.../api.github.com/{repos|orgs|user}/{rest...}
        guard let apiIndex = pathComponents.firstIndex(where: { $0 == "api.github.com" || $0.hasSuffix(".api.github.com") }) else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let afterAPI = pathComponents[(apiIndex + 1)...]
        let components = Array(afterAPI)

        guard !components.isEmpty else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let (scope, remaining): (String, [String]) = {
            switch components[0] {
            case "repos":
                guard components.count >= 3 else {
                    return ("global/other", Array(components))
                }
                return ("repo:\(components[1])/\(components[2])", Array(components.dropFirst(3)))
            case "orgs":
                guard components.count >= 2 else {
                    return ("global/other", Array(components))
                }
                return ("org:\(components[1])", Array(components.dropFirst(2)))
            case "user":
                return ("user", Array(components.dropFirst(1)))
            default:
                return ("global/other", components)
            }
        }()

        return GitHubEndpointKey(scope: scope, endpoint: normalizeEndpoint(remaining))
    }

    /// Maps the remaining path components (after scope) to a stable endpoint category.
    ///
    /// - Parameter components: The path components after the scope prefix.
    /// - Returns: A normalised endpoint category string.
    private func normalizeEndpoint(_ components: [String]) -> String {
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
                return "runs.all"
            }
            _ = rest[1]
            let runSuffix = Array(rest.dropFirst(2))

            if runSuffix.isEmpty {
                return "runs.all"
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
}
