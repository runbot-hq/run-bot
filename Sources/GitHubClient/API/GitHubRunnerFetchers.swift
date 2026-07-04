// GitHubRunnerFetchers.swift
// GitHubClient
import Foundation
import os

// MARK: - Fetch runners

public func fetchRunners(for scopeString: String, decoder: JSONDecoder) async -> [Runner] {
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

private struct RunnersResponse: Codable {
    let runners: [Runner]
}

// MARK: - Fetch active jobs

public func fetchActiveJobs(for scopeString: String, decoder: JSONDecoder) async -> [ActiveJob] {
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

private struct WorkflowRunsResponse: Codable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

private struct WorkflowRun: Codable {
    let id: Int
}
