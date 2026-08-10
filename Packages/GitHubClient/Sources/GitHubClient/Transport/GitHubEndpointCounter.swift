// GitHubEndpointCounter.swift
// GitHubClient

import Foundation

// MARK: - GitHubEndpointKey

/// A normalised key for grouping HTTP responses by scope and endpoint category.
internal struct GitHubEndpointKey: Hashable, Sendable {
    let scope: String
    let endpoint: String
}

// MARK: - GitHubEndpointReport

/// A compact diagnostic report of endpoint activity for a time window.
internal struct GitHubEndpointReport: Sendable {
    let total: Int
    let durationSeconds: Int
    let buckets: [Bucket]

    struct Bucket: Sendable {
        let scope: String
        let endpoint: String
        let statusCounts: [(status: Int, count: Int)]
    }

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
/// category, and HTTP status code, producing a formatted report every ~60 seconds.
internal actor GitHubEndpointCounter {

    private var counts: [GitHubEndpointKey: [Int: Int]] = [:]
    private let clock = ContinuousClock()
    private var windowStartedAt: ContinuousClock.Instant
    private let reportInterval: Duration = .seconds(60)

    init() {
        self.windowStartedAt = clock.now
    }

    /// Records one completed HTTP response and returns a report if the interval has expired.
    @discardableResult
    func record(url: String, statusCode: Int) -> GitHubEndpointReport? {
        let key = normalizeKey(from: url)
        let bucket = counts[key, default: [:]]
        counts[key] = bucket.merging([statusCode: 1], uniquingKeysWith: +)

        let now = clock.now
        guard now - windowStartedAt >= reportInterval else {
            return nil
        }

        let elapsed = windowStartedAt.duration(to: now)
        let ms = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let durationSeconds = (ms + 500) / 1000
        let report = buildReport(durationSeconds: durationSeconds)
        counts.removeAll(keepingCapacity: true)
        windowStartedAt = now
        return report
    }

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
    private func normalizeKey(from url: String) -> GitHubEndpointKey {
        guard let components = URLComponents(string: url),
              let host = components.host else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        guard host == "api.github.com" else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let pathComponents = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        guard pathComponents.count >= 2 else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

        let scope: String
        let remaining: [String]
        if pathComponents[0] == "repos" {
            scope = "repo:\(pathComponents[1])/\(pathComponents[2])"
            remaining = Array(pathComponents.dropFirst(3))
        } else if pathComponents[0] == "orgs" {
            scope = "org:\(pathComponents[1])"
            remaining = Array(pathComponents.dropFirst(2))
        } else {
            return GitHubEndpointKey(scope: "global/other", endpoint: "global/other")
        }

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
    private func normalizeEndpoint(_ components: [String], statusQuery: String?) -> String {
        guard !components.isEmpty else { return "global/other" }
        guard components[0] == "actions" else { return "global/other" }

        let rest = Array(components.dropFirst())

        if rest.first == "runners" { return "runners" }

        if rest.first == "runs" {
            guard rest.count >= 2 else { return categorizeRunsList(statusQuery: statusQuery) }
            _ = rest[1]
            let runSuffix = Array(rest.dropFirst(2))

            if runSuffix.isEmpty { return categorizeRunsList(statusQuery: statusQuery) }
            if runSuffix.first == "status" { return "runs.all" }
            if runSuffix.first == "attempts" { return "run_jobs_attempt" }
            if runSuffix.first == "jobs" { return "run_jobs" }
            if runSuffix.first == "timing" { return "runs.all" }
            return "runs.all"
        }

        if rest.first == "jobs" {
            guard rest.count >= 2 else { return "global/other" }
            let jobSuffix = Array(rest.dropFirst(2))
            if jobSuffix.first == "logs" { return "job_logs" }
            return "job_detail"
        }

        return "global/other"
    }

    /// Categorises a runs list endpoint based on the `status` query parameter.
    private func categorizeRunsList(statusQuery: String?) -> String {
        switch statusQuery {
        case "in_progress": return "runs.in_progress"
        case "queued": return "runs.queued"
        case "completed": return "runs.completed"
        case nil: return "runs.all"
        default: return "runs.other"
        }
    }
}
