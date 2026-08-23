// RunnerPoller+InstallPathMap.swift
// RunBotCore
import Foundation

// MARK: - InstallPathMap

/// Lookup maps built from the local runner list, used by `fetchAndEnrichRunners`.
///
/// `public` so the app target can reference the type (e.g. in tests and in
/// `AppDependencies` for DI wiring). `buildInstallPathMap` is `internal`
/// — it is only called from within `RunBotCore`.
public struct InstallPathMap {
    /// Maps "scope/runnerName" to installPath (exact scope-prefixed match).
    public let byFullKey: [String: String]
    /// Maps "runnerName" to installPath (name-only fallback).
    public let byName: [String: String]
    /// Maps local `.runner` JSON `AgentId` to installPath (scope-agnostic).
    ///
    /// Keyed on `localRunner.agentId`, **not** the GitHub REST API runner id.
    /// Use `byApiId` when resolving API runner ids (they differ for org runners).
    public let byAgentId: [Int: String]
    /// Maps apiId to installPath using the GitHub REST API runner id from the last enrichment cycle.
    ///
    /// For org runners the GitHub API assigns an `id` that differs from the local
    /// `.runner` JSON `AgentId`. This map is keyed on the API id so that metrics
    /// can be resolved for org runners even when `byAgentId` misses.
    ///
    /// Built with per-entry filtering: a runner missing `installPath` or `apiId`
    /// is skipped without affecting the other entries. If two runners ever share
    /// an `apiId`, the last-seen entry wins (dictionary subscript assignment).
    public let byApiId: [Int: String]

    /// Creates an `InstallPathMap` with pre-built lookup dictionaries.
    ///
    /// - Parameters:
    ///   - byFullKey: Maps "scope/runnerName" to installPath.
    ///   - byName: Maps runnerName to installPath (name-only fallback).
    ///   - byAgentId: Maps local `.runner` JSON AgentId to installPath.
    ///   - byApiId: Maps GitHub REST API runner id to installPath.
    public init(
        byFullKey: [String: String],
        byName: [String: String],
        byAgentId: [Int: String],
        byApiId: [Int: String]
    ) {
        self.byFullKey = byFullKey
        self.byName = byName
        self.byAgentId = byAgentId
        self.byApiId = byApiId
    }
}
/// Builds four lookup maps from the local runner list.
///
/// `internal` — called only by `RunnerPoller.fetch()` inside `RunBotCore`.
/// Kept as a top-level free function (rather than `extension RunnerPoller`) so
/// it can be tested without an actor instance.
func buildInstallPathMap(
    scopes: [String],
    localRunners: [RunnerModel]
) -> InstallPathMap {
    var byFullKey: [String: String] = [:]
    var byName: [String: String] = [:]
    var byAgentId: [Int: String] = [:]
    var byApiId: [Int: String] = [:]
    for localRunner in localRunners {
        guard let path = localRunner.installPath else {
            log("RunnerPoller › buildInstallPathMap — SKIP \(localRunner.runnerName): installPath is nil", category: .runner)
            continue
        }
        byName[localRunner.runnerName] = path
        if let agentId = localRunner.agentId {
            byAgentId[agentId] = path
        } else {
            log("RunnerPoller › buildInstallPathMap — \(localRunner.runnerName): agentId is nil (will rely on apiId/fullKey/name fallback)", category: .runner)
        }
        if let apiId = localRunner.apiId {
            byApiId[apiId] = path
        }
        for scope in scopes {
            byFullKey["\(scope)/\(localRunner.runnerName)"] = path
        }
    }
    // swiftlint:disable:next line_length
    log("RunnerPoller › buildInstallPathMap — localRunners=\(localRunners.count) scopes=\(scopes) → fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted()) agentIdKeys=\(byAgentId.keys.sorted()) apiIdKeys=\(byApiId.keys.sorted())", category: .runner)
    if byFullKey.isEmpty && !localRunners.isEmpty {
        // swiftlint:disable:next line_length
        log("RunnerPoller › ⚠️ buildInstallPathMap — fullKey map is EMPTY despite localRunners=\(localRunners.count). Scopes=\(scopes). Check scope string format alignment with localRunner names.", category: .runner)
    }
    if localRunners.isEmpty {
        log("RunnerPoller › ⚠️ buildInstallPathMap — localRunners is EMPTY. All maps are empty. Busy runners will have no installPath this cycle.", category: .runner)
    }
    return InstallPathMap(byFullKey: byFullKey, byName: byName, byAgentId: byAgentId, byApiId: byApiId)
}
