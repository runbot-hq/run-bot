// RunnerStatusEnricher.swift
// RunBotCore
//
// Enriches a list of RunnerModel values with GitHub API data (status, busy, labels, group).
//
// Strategy: batch by unique scope URL.
//   1. Group runners by their gitHubUrl scope (repo or org).
//   2. Issue ONE ghAPI call per unique scope — not one call per runner.
//      Pages through all results (per_page=100) so fleets larger than
//      GitHub's default page size of 30 are fully covered.
//   3. Build a scopeURL → (name → RunnerPayload) dictionary per scope.
//   4. Second pass: apply enrichment from the dictionary, scoped by gitHubUrl.
//
// Scope fetches run concurrently via withTaskGroup — poll latency is bounded
// by the slowest scope rather than the sum of all scopes.
//
// NOTE: fetchRunnersForScope decodes the API response via JSONDecoder + a typed
// Codable struct (RunnerPayload) — no [String: Any] or JSONSerialization.
//
// NOTE: fetchRunnersForScope intentionally does NOT check ghIsRateLimited before
// calling ghAPI. The transport layer (GitHubURLSessionTransport) is the single
// source of truth for rate-limit state. A permission 403 on an org-scope endpoint
// must NOT prevent a subsequent repo-scope fetch from running — the two scopes use
// independent API paths and may have different token permissions.
//
// See: RunnerModel, RunnerStatus
import Foundation
import GitHubClient

// MARK: - Codable payload

/// Typed `Codable` representation of a single runner object returned by the
/// GitHub `/actions/runners` API endpoint.
///
/// Replaces the previous `init?(dict: [String: Any])` approach, eliminating all
/// `JSONSerialization` and `[String: Any]` usage from this file (#1287 Phase 6b).
private struct RunnerPayload: Decodable, Sendable {
    // MARK: Nested types

    /// A single label entry in the `labels` array returned by the GitHub runners API.
    struct Label: Decodable, Sendable {
        /// The label's display name (e.g. `"macos"`, `"arm64"`, `"self-hosted"`).
        let name: String
    }

    // MARK: Stored properties

    /// The GitHub REST API numeric runner ID.
    ///
    /// Stored as `RunnerModel.apiId` after enrichment so that
    /// `RunnerStore.buildInstallPathMap` can build a `byApiId` lookup map —
    /// enabling metrics resolution for org runners whose local `.runner` JSON
    /// `AgentId` differs from this GitHub-assigned id.
    let id: Int?
    /// The runner's display name as registered with GitHub.
    let name: String
    /// The runner's online/offline status string (e.g. `"online"`, `"offline"`).
    let status: String?
    /// Whether the runner is currently executing a job.
    let busy: Bool
    /// The runner group name the runner belongs to, if any.
    let runnerGroupName: String?
    /// The label entries attached to this runner.
    let labels: [Label]

    // MARK: CodingKeys

    /// Maps Swift property names to the snake_case keys used in the GitHub API JSON response.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `id` JSON key.
        case id
        /// Maps to the `name` JSON key.
        case name
        /// Maps to the `status` JSON key.
        case status
        /// Maps to the `busy` JSON key.
        case busy
        /// Maps to the `labels` JSON key.
        case labels
        /// Maps to the `runner_group_name` JSON key.
        case runnerGroupName = "runner_group_name"
    }

    /// Convenience accessor — mirrors the old `APIRunnerPayload.labelNames`.
    var labelNames: [String] { labels.map(\.name) }
}

/// Envelope for the GitHub `/actions/runners` list endpoint.
private struct RunnerListEnvelope: Decodable, Sendable {
    /// Total number of runners registered for the scope (may exceed one page).
    let totalCount: Int
    /// The runner objects returned on this page.
    let runners: [RunnerPayload]

    /// Maps Swift property names to the snake_case keys used in the GitHub API JSON response.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `total_count` JSON key.
        case totalCount = "total_count"
        /// Maps to the `runners` JSON key.
        case runners
    }
}

// MARK: - RunnerStatusEnricher

/// Enriches a `[RunnerModel]` snapshot with live GitHub API data.
///
/// Multiple scopes are fetched concurrently via `withTaskGroup`.
///
/// Conforms to `RunnerStatusEnricherProtocol` so it can be injected into
/// `LocalRunnerStore` (Phase 6b, #1326).
///
/// The `shared` singleton has been intentionally removed (#1539 item 22).
/// Callers must construct an instance explicitly:
/// ```swift
/// LocalRunnerStore(viewModel: vm, enricher: RunnerStatusEnricher())
/// ```
/// This makes the dependency visible at the injection site and allows unit
/// tests to substitute a stub without patching a global.
///
/// - Important: All methods are async. Always call from an async context —
///   never block the main actor waiting for enrichment.
/// - SeeAlso: `RunnerModel`, `RunnerStatus`, `LocalRunnerStore`
public struct RunnerStatusEnricher: RunnerStatusEnricherProtocol, Sendable {

    /// Creates a new `RunnerStatusEnricher` instance.
    public init() { /* No setup required; all enrichment work is stateless. */ }

    /// Enriches `runners` with GitHub API status, busy flag, labels, and runner group.
    ///
    /// Delegates each phase to a private helper to keep cyclomatic complexity low:
    /// 1. `buildScopeToRunnerIndices` — groups runner indices by scope URL.
    /// 2. Concurrent scope fetches via `withTaskGroup`.
    /// 3. `buildFallbackAPI` — merges all scope dicts into a cross-scope fallback.
    /// 4. `applyEnrichmentPass` — second pass applying API data to each runner.
    ///
    /// - Parameter runners: The locally-discovered runner list to enrich.
    /// - Returns: A new array with the same runners, each enriched where an API match was found.
    /// - Note: Runners that are stopped (`isRunning == false`) or whose `gitHubUrl` is `nil`
    ///   are skipped and returned unchanged (#2467).
    public func enrich(runners: [RunnerModel]) async -> [RunnerModel] {
        // Step 1: collect unique scope URLs and the runners belonging to each.
        let scopeToRunnerIndices = buildScopeToRunnerIndices(runners)

        // Step 2: fetch all scopes concurrently.
        // Use (scopeURL, [RunnerPayload]) tuples so results stay scope-keyed.
        // Keying by (scopeURL, name) prevents last-write-wins collisions when two
        // scopes (e.g. org + repo) expose a runner with the same registered name.
        var apiByScope: [String: [String: RunnerPayload]] = [:]
        await withTaskGroup(of: (String, [RunnerPayload]).self) { group in
            for scopeURL in scopeToRunnerIndices.keys {
                group.addTask { (scopeURL, await self.fetchRunnersForScope(scopeURL)) }
            }
            for await (scopeURL, fetched) in group {
                apiByScope[scopeURL] = Dictionary(
                    fetched.map { ($0.name, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }

        // Step 3: build the cross-scope fallback dict then apply enrichment.
        let fallbackAPI = buildFallbackAPI(from: apiByScope)
        return applyEnrichmentPass(to: runners, apiByScope: apiByScope, fallbackAPI: fallbackAPI)
    }

    // MARK: - Private helpers

    /// Groups runner indices by their scope URL string.
    ///
    /// Runners whose `isRunning` is `false` or whose `gitHubUrl` is `nil` are
    /// skipped and a diagnostic log entry is emitted. Stopped runners are excluded
    /// so they do not trigger GitHub API calls during enrichment (#2467).
    /// Extracted from `enrich` to reduce its cyclomatic complexity.
    ///
    /// - Parameter runners: The full runner list passed to `enrich`.
    /// - Returns: A mapping from absolute scope URL string to the indices of runners
    ///   that belong to that scope.
    func buildScopeToRunnerIndices(_ runners: [RunnerModel]) -> [String: [Int]] {
        var scopeToRunnerIndices: [String: [Int]] = [:]
        for (idx, runner) in runners.enumerated() {
            guard runner.isRunning, let url = runner.gitHubUrl else {
                if !runner.isRunning {
                    log("[Enricher] SKIP '\(runner.runnerName)' — isRunning is false", category: .runner)
                } else {
                    log("[Enricher] SKIP '\(runner.runnerName)' — gitHubUrl is nil", category: .runner)
                }
                continue
            }
            scopeToRunnerIndices[url.absoluteString, default: []].append(idx)
        }
        return scopeToRunnerIndices
    }

    /// Merges all per-scope payload dictionaries into a single cross-scope fallback.
    ///
    /// When two scopes contain a runner registered under the same name, the first
    /// writer wins and a warning is logged. Extracted from `enrich` to reduce its
    /// cyclomatic complexity.
    ///
    /// - Parameter apiByScope: The fully-populated per-scope payload dictionaries
    ///   produced after all concurrent `fetchRunnersForScope` calls complete.
    /// - Returns: A flat `[name: RunnerPayload]` dictionary covering all scopes.
    ///
    /// - Note: `fallbackAPI` is computed once here — `apiByScope` is immutable at
    ///   call time, so recomputing the merged dict inside the apply loop would be
    ///   O(N×S) work for no benefit.
    private func buildFallbackAPI(from apiByScope: [String: [String: RunnerPayload]]) -> [String: RunnerPayload] {
        var seenInFallback: [String: String] = [:]
        return apiByScope.reduce(into: [String: RunnerPayload]()) { result, entry in
            let (scopeURL, scopeDict) = entry
            for (name, payload) in scopeDict {
                if result[name] != nil {
                    log(
                        "[Enricher] ⚠️ fallback collision: runner '\(name)' appears in both '\(seenInFallback[name] ?? "?")' and '\(scopeURL)' — first-writer wins",
                        category: .runner
                    )
                } else {
                    result[name] = payload
                    seenInFallback[name] = scopeURL
                }
            }
        }
    }

    /// Applies API payloads to each runner in `runners` and returns the enriched array.
    ///
    /// For each runner the lookup prefers the runner's own scope (`apiByScope`) before
    /// falling back to the merged cross-scope dict (`fallbackAPI`). Runners with no
    /// matching payload are returned unchanged and a diagnostic log entry is emitted.
    /// Extracted from `enrich` to reduce its cyclomatic complexity.
    ///
    /// - Parameters:
    ///   - runners: The original runner list passed to `enrich`.
    ///   - apiByScope: Per-scope payload dictionaries keyed by scope URL string.
    ///   - fallbackAPI: The merged cross-scope payload dictionary from `buildFallbackAPI`.
    /// - Returns: The enriched runner array.
    private func applyEnrichmentPass(
        to runners: [RunnerModel],
        apiByScope: [String: [String: RunnerPayload]],
        fallbackAPI: [String: RunnerPayload]
    ) -> [RunnerModel] {
        var result = runners
        for idx in result.indices {
            let name = result[idx].runnerName
            // Restrict lookup to the runner's own scope first to avoid cross-scope
            // name collisions, then fall back to a scan across all scopes.
            let scopedAPI = result[idx].gitHubUrl.flatMap { apiByScope[$0.absoluteString] } ?? [:]
            if let api = Self.findPayload(name: name, in: scopedAPI) ?? Self.findPayload(name: name, in: fallbackAPI) {
                result[idx] = applyEnrichment(to: result[idx], from: api)
            } else {
                let gitHubUrl = result[idx].gitHubUrl?.absoluteString ?? "NIL"
                log("[Enricher] NO MATCH for '\(name)' — available API names: \(scopedAPI.keys.sorted()) gitHubUrl=\(gitHubUrl)", category: .runner)
            }
        }
        return result
    }

    /// Looks up a `RunnerPayload` for `name` in `dict` using four strategies:
    /// exact match → case-insensitive match → whitespace-trimmed match →
    /// combined trim + lowercase match.
    ///
    /// Extracted from the `for idx in result.indices` loop body so it is
    /// independently testable (P13) and free of mutable outer-loop capture (P16).
    ///
    /// - Parameters:
    ///   - name: The runner name to look up.
    ///   - dict: The payload dictionary keyed by runner name.
    /// - Returns: The matching payload, or `nil` if none is found.
    ///
    /// Lookup stages (applied in order, first match wins):
    /// 1. Exact match — `dict[name]`.
    /// 2. Case-insensitive — both sides lowercased, whitespace untouched.
    /// 3. Whitespace-trimmed — both sides trimmed, case untouched.
    /// 4. Combined — both sides trimmed *and* lowercased, handles names that
    ///    differ in both casing and surrounding whitespace (e.g. `" MyRunner"`
    ///    vs `"myrunner"`).
    private static func findPayload(name: String, in dict: [String: RunnerPayload]) -> RunnerPayload? {
        if let api = dict[name] { return api }
        let nameLower = name.lowercased()
        if let key = dict.keys.first(where: { $0.lowercased() == nameLower }) { return dict[key] }
        let nameTrimmed = name.trimmingCharacters(in: .whitespaces)
        if let key = dict.keys.first(where: { $0.trimmingCharacters(in: .whitespaces) == nameTrimmed }) { return dict[key] }
        let nameNormalized = nameTrimmed.lowercased()
        if let key = dict.keys.first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == nameNormalized }) { return dict[key] }
        return nil
    }

    /// Fetches the **complete** runner list for a scope URL via ghAPI, paginating
    /// through all pages (per_page=100) until exhausted.
    ///
    /// - Parameter scopeURL: The full GitHub URL for the repo or org scope.
    /// - Returns: All runner payloads collected across all pages. Empty on failure.
    ///
    /// GitHub's default page size is 30. Without explicit pagination any org/repo
    /// with more than 30 runners would silently lose enrichment for runners beyond
    /// the first page. Using per_page=100 (the API maximum) minimises round-trips.
    ///
    /// - Note: This method intentionally does NOT gate on `ghIsRateLimited`. A permission
    ///   403 on one scope (e.g. org) must not block a repo-scope fetch from running.
    ///   The transport layer handles real rate-limits; duplicating the check here causes
    ///   false skips when scopes are fetched concurrently and an org 403 fires first.
    private func fetchRunnersForScope(_ scopeURL: String) async -> [RunnerPayload] {
        let stripped = scopeURL.replacingOccurrences(of: GitHubConstants.base + "/", with: "")
        let parts = stripped.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }

        // ⚠️ No leading slash — ghAPI builds the full URL itself.
        let baseEndpoint: String
        if parts.count >= 2 {
            baseEndpoint = "repos/\(parts[0])/\(parts[1])/actions/runners"
        } else {
            baseEndpoint = "orgs/\(parts[0])/actions/runners"
        }

        var allRunners: [RunnerPayload] = []
        var page = 1
        let perPage = 100
        let decoder = JSONDecoder()

        while true {
            let endpoint = "\(baseEndpoint)?per_page=\(perPage)&page=\(page)"
            guard let data = await ghAPI(endpoint) else {
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) — ghAPI returned nil", category: .runner)
                break
            }
            do {
                let envelope = try decoder.decode(RunnerListEnvelope.self, from: data)
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) returned \(envelope.runners.count) runners (total_count=\(envelope.totalCount))", category: .runner)
                allRunners.append(contentsOf: envelope.runners)
                guard envelope.runners.count == perPage,
                      allRunners.count < envelope.totalCount else { break }
                page += 1
            } catch {
                log("[Enricher] fetchRunnersForScope \(scopeURL) page \(page) — JSONDecoder failed: \(error)", category: .runner)
                break
            }
        }

        log("[Enricher] fetchRunnersForScope \(scopeURL) total collected \(allRunners.count) runners", category: .runner)
        return allRunners
    }

    /// Applies fields from a `RunnerPayload` to a `RunnerModel`.
    ///
    /// - Returns: A new `RunnerModel` with API-sourced fields applied.
    /// - Note: Platform and architecture are derived from API labels when the `.runner`
    ///   JSON on disk did not supply them (older runner agent versions omit these fields).
    ///   Prefer label-derived values (always correctly cased by GitHub)
    ///   over whatever `.runner` JSON provided (often nil or raw OS strings).
    private func applyEnrichment(to runner: RunnerModel, from api: RunnerPayload) -> RunnerModel {
        let githubStatus = api.status.map { RunnerStatus(rawString: $0) }
        let effectiveLabels = api.labelNames.isEmpty ? runner.labels : api.labelNames
        let labelPlatform = effectiveLabels.first(where: { label in
            let lowercased = label.lowercased()
            return lowercased == "macos" || lowercased == "linux" || lowercased == "windows"
        })
        let labelArch = effectiveLabels.first(where: { label in
            let lowercased = label.lowercased()
            return lowercased == "arm64" || lowercased == "x64" || lowercased == "x86" || lowercased == "aarch64"
        })
        let platform = labelPlatform ?? runner.platform
        let platformArchitecture = labelArch ?? runner.platformArchitecture

        return RunnerModel(
            id: runner.id,
            runnerName: runner.runnerName,
            gitHubUrl: runner.gitHubUrl,
            agentId: runner.agentId,
            apiId: api.id,
            workFolder: runner.workFolder,
            installPath: runner.installPath,
            isRunning: runner.isRunning,
            labels: effectiveLabels,
            githubStatus: githubStatus,
            isBusy: api.busy,
            lifecycleWarning: runner.lifecycleWarning,
            platform: platform,
            platformArchitecture: platformArchitecture,
            agentVersion: runner.agentVersion,
            isEphemeral: runner.isEphemeral,
            runnerGroup: api.runnerGroupName,
            metrics: runner.metrics
        )
    }
}
