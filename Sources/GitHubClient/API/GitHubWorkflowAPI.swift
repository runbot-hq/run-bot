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
public struct GitHubJob: Decodable, Identifiable, Equatable, Sendable {
    /// Unique numeric job ID assigned by GitHub.
    public let id: Int
    /// The workflow run this job belongs to. Maps the `run_id` JSON field.
    public let runID: Int
    /// Display name of the job.
    public let name: String
    /// Raw status string — NOT `JobStatus` (a RunBotCore type).
    public let status: String
    /// Raw conclusion string — NOT `JobConclusion` (a RunBotCore type).
    public let conclusion: String?
    /// GitHub web URL for this job.
    public let htmlUrl: String?
    /// Name of the runner executing this job, or `nil` if not yet assigned.
    public let runnerName: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let startedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let completedAt: String?
    /// Raw ISO 8601 date string — caller is responsible for parsing.
    public let createdAt: String?
    /// Steps within this job.
    public let steps: [GitHubStep]

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
        // Queued jobs have no steps array in the API response — fall back to []
        steps = (try? container.decodeIfPresent([GitHubStep].self, forKey: .steps)) ?? []
    }

    /// Full memberwise initialiser — used by `copying(...)` helpers and tests.
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
        self.id = id; self.runID = runID; self.name = name; self.status = status
        self.conclusion = conclusion; self.htmlUrl = htmlUrl
        self.runnerName = runnerName; self.startedAt = startedAt
        self.completedAt = completedAt; self.createdAt = createdAt
        self.steps = steps
    }

    // MARK: copying helpers — used by ActiveJob.withUpdatedRaw

    /// Returns a copy of this job with `runnerName` replaced.
    public func copying(runnerName newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: newValue, startedAt: startedAt,
                  completedAt: completedAt, createdAt: createdAt, steps: steps)
    }

    /// Returns a copy of this job with `startedAt` replaced.
    public func copying(startedAt newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: newValue,
                  completedAt: completedAt, createdAt: createdAt, steps: steps)
    }

    /// Returns a copy of this job with `completedAt` replaced.
    public func copying(completedAt newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: newValue, createdAt: createdAt, steps: steps)
    }

    /// Returns a copy of this job with `createdAt` replaced.
    public func copying(createdAt newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: completedAt, createdAt: newValue, steps: steps)
    }

    /// Returns a copy of this job with `steps` replaced.
    public func copying(steps newValue: [GitHubStep]) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: conclusion, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: completedAt, createdAt: createdAt, steps: newValue)
    }

    /// Returns a copy of this job with `conclusion` replaced.
    public func copying(conclusion newValue: String?) -> GitHubJob {
        GitHubJob(id: id, runID: runID, name: name, status: status,
                  conclusion: newValue, htmlUrl: htmlUrl,
                  runnerName: runnerName, startedAt: startedAt,
                  completedAt: completedAt, createdAt: createdAt, steps: steps)
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

    /// Memberwise initialiser — used by tests and `copying(...)` helpers.
    ///
    /// `GitHubStep` is `Decodable`-only in production, but tests construct
    /// steps directly. This init bridges that gap without requiring
    /// `@testable` access to an internal init.
    public init(
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
public enum GitHubRunsFetchResult: Sendable {
    /// All pages fetched successfully.
    case success([GitHubWorkflowRun])
    /// Rate limit hit mid-fetch — results are valid but may be incomplete.
    case rateLimited([GitHubWorkflowRun])
    /// Token was rejected (401/403 without rate-limit headers) — discard everything.
    case authFailure
    /// No GitHub token is configured.
    case noToken
}

// MARK: - API

/// Fetches active (queued + in_progress) workflow runs for a scope.
@concurrent
public func fetchActiveRuns(scope: Scope) async -> GitHubRunsFetchResult {
    let statuses = ["in_progress", "queued"]
    var allRuns: [GitHubWorkflowRun] = []
    var seenIDs = Set<Int>()
    for status in statuses {
        let endpoint = "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=\(GitHubConstants.activeRunsPageSize)"
        guard let data = await ghAPIPaginated(endpoint) else {
            if allRuns.isEmpty { return .noToken } else { return .rateLimited(allRuns) }
        }
        struct Response: Decodable {
            let workflowRuns: [GitHubWorkflowRun]
            enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
        }
        if let decoded = try? JSONDecoder().decode(Response.self, from: data) {
            for run in decoded.workflowRuns where seenIDs.insert(run.id).inserted {
                allRuns.append(run)
            }
        }
    }
    return .success(allRuns)
}

/// Fetches all jobs for a given workflow run ID.
@concurrent
public func fetchJobs(runID: Int, scope: Scope) async -> [GitHubJob] {
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)"
    guard let data = await ghAPIPaginated(endpoint) else { return [] }
    struct Response: Decodable { let jobs: [GitHubJob] }
    return (try? JSONDecoder().decode(Response.self, from: data))?.jobs ?? []
}
