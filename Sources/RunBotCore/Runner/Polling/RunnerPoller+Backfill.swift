// RunnerPoller+Backfill.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - RunnerPoller: step backfill

/// Helpers for backfilling step data into completed-job cache entries.
extension RunnerPoller {
    /// Backfills step data into the completed-job cache.
    ///
    /// Iterates jobs in `cache` that have a conclusion but missing or in-progress steps,
    /// fetches the full job payload from the GitHub API, and updates the cache entry.
    ///
    /// **Eviction rationale — these are NOT data-loss bugs:**
    /// Three categories of cache entry are evicted (via `removeValue`) rather than
    /// skipped or retried. Each is intentional and self-correcting:
    ///
    /// 1. **`scope == nil` (pre-scope-injection entries)**
    ///    Written before scope-injection was introduced (pre-F-26). As of F-26,
    ///    `fetchAllJobs` always injects scope via `.copying(scope:)` at fetch time,
    ///    so `scope == nil` entries should only appear in the first poll cycle after
    ///    an upgrade from a pre-F-26 build. Evicting them prevents repeated per-poll
    ///    warning spam. They re-enter the cache with correct scope data on the next
    ///    poll cycle once a new live fetch completes. This flash is cosmetic and
    ///    self-corrects within one poll cycle.
    ///    TODO: Remove this guard after two release cycles once pre-F-26 cache
    ///    entries are definitively gone from the field.
    ///
    /// 2. **Org-only scope (`!scope.contains("/")`)**
    ///    The GitHub Jobs API has no `orgs/{org}/actions/jobs/{id}` endpoint — only
    ///    `repos/{owner}/{repo}/actions/jobs/{id}`. Keeping these entries would log a
    ///    warning every poll cycle with no path to ever resolve them. Eviction is a
    ///    one-time operation; the entry cannot re-populate via any backfill path
    ///    (no GitHub org/actions/jobs endpoint exists).
    ///
    /// 3. **Empty-steps API response**
    ///    Early-queued jobs may return zero steps transiently. The guard
    ///    `guard !updated.steps.isEmpty` keeps the existing cache entry unchanged and
    ///    retries on the next poll — this is a *skip*, not an eviction.
    ///
    /// The `removeValue` calls for cases 1 and 2 are therefore intentional, not data loss.
    func backfillSteps(into cache: inout [Int: ActiveJob]) async {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            // ActiveJob exposes jobConclusion (JobConclusion?) not conclusion (String?).
            guard cached.jobConclusion != nil else { continue }
            // GitHubStep.status is a raw String — compare via stepStatus typed accessor.
            guard cached.steps.isEmpty || cached.steps.contains(where: { (step: GitHubStep) in
                step.stepStatus == .inProgress
            }) else { continue }
            guard let scope = validRepoScope(for: cached, jobID: cacheID, cache: &cache) else { continue }
            guard let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)") else { continue }
            if let refreshed = await decodedBackfillJob(data, jobID: cacheID, existingScope: cached.scope) {
                cache[cacheID] = refreshed
            }
        }
    }
}
