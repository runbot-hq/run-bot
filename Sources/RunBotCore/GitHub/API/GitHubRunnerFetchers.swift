// GitHubRunnerFetchers.swift
// RunBotCore
//
// Step 7: Rewrite — all JSON decoding removed. Delegates entirely to the
// free functions added to GitHubClient in Steps 1 and 2. Inline
// WorkflowRunsResponse / WorkflowRun / JobsResponse private structs deleted.

import GitHubClient
import os

// MARK: - Fetch runners

/// Fetches all registered self-hosted runners for the given scope string.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) formats.
///
/// Delegates to `fetchRunners(scopeString:)` in `GitHubClient` which handles
/// pagination automatically. The `decoder` parameter is kept for call-site
/// compatibility but is no longer used internally.
///
/// - Parameters:
///   - scopeString: A repo path (`owner/repo`) or org name.
///   - decoder: Unused — retained for call-site compatibility.
/// - Returns: An array of `GitHubRunner` values, or empty on failure.
func fetchRunners(for scopeString: String, decoder: JSONDecoder) async -> [GitHubRunner] {
    guard let runners = await fetchRunners(scopeString: scopeString) else {
        log("fetchRunners › invalid scope: \(scopeString)")
        return []
    }
    log("fetchRunners › \(runners.count) runner(s) for \(scopeString)")
    return runners
}

// MARK: - Fetch active jobs

/// Fetches all active (in-progress and queued) jobs for a given scope.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) runners.
///
/// Delegates to `fetchActiveRuns(scope:)` and `fetchJobs(runID:scope:)` in
/// `GitHubClient`. All JSON decoding and pagination are handled there.
/// The `decoder` parameter is kept for call-site compatibility but is no
/// longer used internally.
///
/// - Parameters:
///   - scopeString: A repo path (`owner/repo`) or org name.
///   - decoder: Unused — retained for call-site compatibility.
/// - Returns: An array of `ActiveJob` values, or empty on failure.
func fetchActiveJobs(for scopeString: String, decoder: JSONDecoder) async -> [ActiveJob] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchActiveJobs › invalid scope: \(scopeString)")
        return []
    }

    let result = await fetchActiveRuns(scope: scope)
    let runs: [GitHubWorkflowRun]
    switch result {
    case .success(let fetchedRuns):
        runs = fetchedRuns
    case .rateLimited(let partialRuns):
        log("fetchActiveJobs › rate limited — \(partialRuns.count) partial run(s)")
        runs = partialRuns
    case .authFailure:
        log("fetchActiveJobs › auth failure")
        return []
    case .noToken:
        log("fetchActiveJobs › no token")
        return []
    }

    var jobs: [ActiveJob] = []
    var seen = Set<Int>()
    for run in runs {
        let rawJobs = await fetchJobs(runID: run.id, scope: scope)
        for raw in rawJobs where seen.insert(raw.id).inserted {
            jobs.append(ActiveJob(raw: raw))
        }
    }

    log("fetchActiveJobs › \(jobs.count) job(s) for \(scopeString)")
    return jobs
}
