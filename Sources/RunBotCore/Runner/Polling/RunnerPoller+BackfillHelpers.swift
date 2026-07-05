// RunnerPoller+BackfillHelpers.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - Backfill helpers

// swiftlint:disable:next missing_docs
extension RunnerPoller {
    /// Validates and returns the repo-scoped path for a cached job, evicting entries that
    /// lack a scope or carry an org-only scope (neither can be backfilled via the API).
    /// Returns `nil` in both eviction cases so the caller can `continue` immediately.
    func validRepoScope(
        for job: ActiveJob,
        jobID: Int,
        cache: inout [Int: ActiveJob]
    ) -> String? {
        guard let scope = job.scope else {
            cache.removeValue(forKey: jobID)
            log(
                "RunnerPoller › backfillSteps — evicted jobID=\(jobID): scope is nil (pre-scope-injection entry)",
                category: .runner)
            return nil
        }
        guard scope.contains("/") else {
            cache.removeValue(forKey: jobID)
            log(
                "RunnerPoller › backfillSteps — evicted jobID=\(jobID): org-only scope '\(scope)' has no repo path; org-only jobs cannot be backfilled (no GitHub org/actions/jobs endpoint)",
                category: .runner)
            return nil
        }
        return scope
    }

    /// Decodes a raw API response into an `ActiveJob` for replacing a backfill cache entry.
    /// Restores the original scope (absent from the API payload) and guards against empty-steps
    /// responses that would clobber valid cached step data. Returns `nil` on failure or 0 steps.
    func decodedBackfillJob(
        _ rawData: Data,
        jobID: Int,
        existingScope: String?
    ) async -> ActiveJob? {
        do {
            // JobPayload renamed to GitHubJob in Step 5/8 refactor.
            let payload = try decoder.decode(GitHubJob.self, from: rawData)
            let updated = ActiveJob(raw: payload, isDimmed: true)
            guard !updated.steps.isEmpty else {
                log(
                    "RunnerPoller › backfillSteps — jobID=\(jobID) API returned 0 steps, keeping existing cache entry",
                    category: .runner)
                return nil
            }
            return updated.copying(scope: existingScope)
        } catch {
            log(
                "RunnerPoller › backfillSteps — ⚠️ decode failed for jobID=\(jobID): \(error)",
                category: .runner)
            return nil
        }
    }
}
