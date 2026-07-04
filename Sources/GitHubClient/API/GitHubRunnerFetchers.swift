// GitHubRunnerFetchers.swift
// GitHubClient
//
// Step 10: Free functions that fetch runners and active jobs from the GitHub API.
// Moved from RunBot/GitHub/GitHubHelpers.swift so RunnerPoller (now in Core)
// can call them without an app-layer dependency.
import Foundation
import os

// MARK: - Fetch runners

/// Fetches all registered self-hosted runners for the given scope string.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) formats.
/// - Parameters:
///   - scopeString: A repo path (`owner/repo`) or org name.
///   - decoder: A shared `JSONDecoder` instance. Pass `RunnerPoller.decoder` so the
///     actor's reusable instance is used instead of allocating a new one per call.
/// - Returns: An array of `Runner` values, or empty on failure.
func fetchRunners(for scopeString: String, decoder: JSONDecoder) async -> [Runner] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRunners › invalid scope: \(scopeString)")
        return []
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners"
    log("fetchRunners › \(endpoint)")
    guard let data = await ghAPI(endpoint) else {
        log("fetchRunners › no data for scope: \(scopeString)")
        return []
    }
    guard let response = try? decoder.decode(RunnersResponse.self, from: data) else {
        log("fetchRunners › decode failed for scope: \(scopeString)")
        return []
    }
    log("fetchRunners › found \(response.runners.count) runner(s) for \(scopeString)")
    return response.runners
}

/// Response envelope for the runners list API endpoint.
private struct RunnersResponse: Codable {
    /// The list of runners returned by the API.
    let runners: [Runner]
}

// MARK: - Fetch active jobs

/// Fetches all active (in-progress and queued) jobs for a given scope.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) runners.
/// Date parsing goes through `ISO8601DateParser.shared` — one actor, one formatter.
/// - Parameters:
///   - scopeString: A repo path (`owner/repo`) or org name.
///   - decoder: A shared `JSONDecoder` instance. Pass `RunnerPoller.decoder` so the
///     actor's reusable instance is used instead of allocating a new one per call.
/// - Returns: An array of `ActiveJob` values, or empty on failure.
func fetchActiveJobs(for scopeString: String, decoder: JSONDecoder) async -> [ActiveJob] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchActiveJobs › invalid scope: \(scopeString)")
        return []
    }
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    func runsEndpoint(status: String) -> String {
        "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=\(GitHubConstants.activeRunsPageSize)"
    }

    for status in ["in_progress", "queued"] {
        guard let data = await ghAPI(runsEndpoint(status: status)),
              let resp = try? decoder.decode(WorkflowRunsResponse.self, from: data)
        else { continue }
        for run in resp.workflowRuns {
            guard seenRunIDs.insert(run.id).inserted else { continue }
            runIDs.append(run.id)
        }
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    for runID in runIDs {
        guard let data = await ghAPI("\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)"),
              let resp = try? decoder.decode(JobsResponse.self, from: data)
        else { continue }
        for payload in resp.jobs {
            guard seenJobIDs.insert(payload.id).inserted else { continue }
            jobs.append(await ISO8601DateParser.shared.makeJob(from: payload, isDimmed: false))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scopeString)")
    return jobs
}

/// Response envelope for the workflow runs list API endpoint.
private struct WorkflowRunsResponse: Codable {
    /// The list of workflow runs returned by the API.
    let workflowRuns: [WorkflowRun]
    /// Maps the snake_case `workflow_runs` key to the camelCase Swift property.
    enum CodingKeys: String, CodingKey {
        /// Maps `workflow_runs` JSON key to `workflowRuns`.
        case workflowRuns = "workflow_runs"
    }
}

/// Minimal workflow run payload — only the run ID is needed for job fetching.
private struct WorkflowRun: Codable {
    /// The unique run identifier.
    let id: Int
}
