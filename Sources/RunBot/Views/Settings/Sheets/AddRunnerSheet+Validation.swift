// AddRunnerSheet+Validation.swift
// RunBot

import Foundation
import RunBotCore

/// Computed validation helpers and state-check predicates for `AddRunnerSheet`.
extension AddRunnerSheet {

    // MARK: - Helpers (Add new)

    /// The resolved scope string — the selected repo slug when repo-scoped,
    /// or the selected organisation name when org-scoped.
    var effectiveScope: String { scopeType == .repo ? selectedRepo : selectedOrg }

    /// Returns `true` when the chosen install directory already contains a `.runner` file,
    /// preventing accidental double-registration of the same path.
    var dirAlreadyConfigured: Bool {
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        )
    }

    /// Guards the Register button: requires a non-empty runner name, a selected scope,
    /// and an install directory that has not already been configured.
    var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
            && !dirAlreadyConfigured
    }

    // MARK: - Helpers (Add pre-existing)

    /// The GitHub URL to use for the import: detected from `.runner` or the manual override.
    var effectiveGitHubURL: String {
        detectedGitHubURL.isEmpty
            ? githubURLOverride.trimmingCharacters(in: .whitespaces)
            : detectedGitHubURL
    }

    /// Returns `true` when all pre-existing import preconditions are met: a runner name was
    /// detected, no parse error occurred, the runner is not already tracked, and a GitHub URL
    /// is available.
    var canImport: Bool {
        !detectedName.isEmpty
            && existingError == nil
            && !isDuplicate
            && !effectiveGitHubURL.isEmpty
    }

    /// Returns `true` when the given runner name is already present in the pushed
    /// `appState.runnerState.localRunners` snapshot — avoids crossing the actor boundary in a
    /// synchronous computed property.
    func checkDuplicate(runnerName: String) -> Bool {
        appState.runnerState.localRunners.contains(where: { $0.runnerName == runnerName })
    }
}
