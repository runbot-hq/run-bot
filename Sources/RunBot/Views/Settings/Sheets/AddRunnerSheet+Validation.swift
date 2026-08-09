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

    /// Returns `true` when the runner name is a valid single path component.
    ///
    /// A valid component is non-empty, is not `.` or `..`, and contains no `/`.
    var runnerNameIsValidPathComponent: Bool {
        let name = trimmedRunnerName
        guard !name.isEmpty else { return false }
        guard name != ".", name != ".." else { return false }
        return !name.contains("/")
    }

    /// Final filesystem path for the new runner.
    ///
    /// Combines the selected parent directory with the trimmed runner name.
    /// Returns `nil` until both values are valid.
    var finalInstallPath: String? {
        let parent = installDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parent.isEmpty, runnerNameIsValidPathComponent else { return nil }
        return URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(trimmedRunnerName, isDirectory: true)
            .standardizedFileURL
            .path
    }

    /// Returns `true` when the derived final runner path already contains a `.runner` file,
    /// preventing accidental double-registration of the same path.
    var dirAlreadyConfigured: Bool {
        guard let finalPath = finalInstallPath else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: finalPath, isDirectory: true)
                .appendingPathComponent(".runner").path
        )
    }

    /// Guards the Register button: requires a valid runner name, a valid final path,
    /// a selected scope, and a directory that has not already been configured.
    var canRegister: Bool {
        !trimmedRunnerName.isEmpty
            && runnerNameIsValidPathComponent
            && finalInstallPath != nil
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
