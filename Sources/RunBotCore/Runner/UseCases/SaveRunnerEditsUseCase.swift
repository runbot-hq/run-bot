// SaveRunnerEditsUseCase.swift
// RunBotCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation
import GitHubClient

// MARK: - LabelsPrerequisiteError

/// Typed errors used internally when the labels-update prerequisite check fails in
/// `SaveRunnerEditsUseCase`. Each case is converted to a human-readable string by
/// `labelsPrereqErrorMessage(_:)` before being surfaced in `execute(…)`'s `CommitResult`.
/// External callers receive only `[String]` errors — this enum is an implementation detail (#1480).
package enum LabelsPrerequisiteError: Error, Equatable, Sendable {
    /// The runner has no `agentId` — required to address the GitHub API runner endpoint.
    case missingAgentId
    /// The runner has no `gitHubUrl` — required to determine the API scope.
    case missingGitHubUrl
    /// The runner has a `gitHubUrl` but it carries no org/repo path components
    /// (e.g. a bare-host URL like `https://github.com`), so no API scope can be derived.
    case invalidScope(URL)
}

// MARK: - SaveRunnerEditsUseCase

/// Testable, dependency-injected replacement for the `commitRunnerEdit` free function.
///
/// Executes the three-step commit transaction:
/// 1. **Labels** (GitHub API) — aborts the entire commit on API failure.
///    If `agentId` or `gitHubUrl` are unavailable, the labels step cannot
///    run; an error is appended and execution **continues** to local writes
///    (steps 2 and 3). This is intentional: missing metadata is not the user's
///    fault and local config writes are still meaningful.
/// 2. **Runner JSON** — writes `workFolder` + `disableUpdate` via `configStore`.
/// 3. **Proxy files** — writes `.proxy` + `.proxycredentials` via `proxyStore`.
///
/// **Error semantics:**
/// - Labels API returns `nil` → immediate abort (steps 2 and 3 are skipped).
/// - Missing `agentId`/`gitHubUrl` → error appended, execution continues.
/// - JSON and proxy errors → accumulated independently; both steps always run
///   when applicable. Config write errors — including `malformedExistingFile`
///   and `ioReadFailedDuringSave` — are accumulated and do not abort step 3.
/// - `installPath == nil` while a JSON *or* proxy change is pending → immediate
///   abort with the accumulated errors so far. Without a known install path there
///   is no safe target for further writes. The `missingInstallPathForJSON` and
///   `missingInstallPathForProxy` tests document this behaviour explicitly.
///
/// All dependencies are injected — no singletons are accessed inside `execute(...)`.
/// Use `RunnerConfigStore.shared`, `RunnerProxyStore.shared`, and
/// `DefaultRunnerLabelsService()` for production.
///
/// - Note: Part of Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
public struct SaveRunnerEditsUseCase: Sendable {

    // MARK: Dependencies

    /// Store for reading and writing the `.runner` JSON config file.
    public let configStore: any RunnerConfigStoreProtocol
    /// Store for reading and writing `.proxy` / `.proxycredentials` files.
    public let proxyStore: any RunnerProxyStoreProtocol
    /// Service for updating runner labels via the GitHub API.
    public let labelsService: any RunnerLabelsService

    // MARK: - Init

    /// Creates a `SaveRunnerEditsUseCase` with the given dependency implementations.
    /// Pass `RunnerConfigStore.shared`, `RunnerProxyStore.shared`, and
    /// `DefaultRunnerLabelsService()` for production use.
    public init(
    /// Initializes a new instance of SaveRunnerEditsUseCase.
    ///
    /// - Parameters:
    ///   - configStore: The runner configuration store.
    ///   - proxyStore: The runner proxy store.
    ///   - labelsService: The service for updating runner labels via GitHub API.
    init(
        configStore: any RunnerConfigStoreProtocol,
        proxyStore: any RunnerProxyStoreProtocol,
        labelsService: any RunnerLabelsService
    ) {
        self.configStore = configStore
        self.proxyStore = proxyStore
        self.labelsService = labelsService
    }

    // MARK: - execute

    /// Persists all changed fields in `draft` for `runner` as a single transaction.
    ///
    /// Ownership conventions:
    /// - `draft` is `consuming` — enforces one-shot commit semantics at compile time;
    ///   the call site cannot reuse the draft after passing it here.
    /// - `runner` and `original` are `borrowing` — read-only baselines that are never
    ///   mutated or stored. Both types conform to `Sendable`, which makes the borrow
    ///   safe across the `await` suspension points inside this function.
    ///
    /// - Returns: `.success` when all writes succeed;
    ///   `.failure([String])` with human-readable messages otherwise.
    public func execute(
        runner: borrowing RunnerModel,
        draft: consuming RunnerEditDraft,
        original: borrowing RunnerEditDraft
    ) async -> CommitResult {
        var errors: [String] = []

        // MARK: Step 1 — Labels (GitHub API)
        let labelsChanged = draft.parsedLabels != original.parsedLabels
        if labelsChanged {
            switch labelsPrerequisite(runner: runner) {
            case .success(let (agentId, scope)):
                let result = await labelsService.patch(scope: scope, runnerID: agentId, labels: draft.parsedLabels)
                if result == nil {
                    return .failure(["Failed to save labels via GitHub API"])
                }
            case .failure(let prereqError):
                errors.append(labelsPrereqErrorMessage(prereqError))
            }
        }

        // MARK: Step 2 — Runner JSON (workFolder + disableUpdate)
        let workFolderChanged = draft.trimmedWorkFolder != original.trimmedWorkFolder
        let autoUpdateChanged = draft.autoUpdate != original.autoUpdate
        if workFolderChanged || autoUpdateChanged {
            // Early return when installPath is nil: there is no safe target for
            // any further writes, so continuing would be a no-op. The proxy step
            // is also skipped — see the "Error semantics" section in the type doc.
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write runner JSON")
                return .failure(errors)
            }
            do {
                var config = try await configStore.load(at: installPath)
                config.workFolder = draft.trimmedWorkFolder
                // Assign nil (key omitted) when auto-update is enabled — the agent
                // treats key-absent and false identically, but omitting keeps the
                // file idiomatic. Only write true when the user explicitly disables.
                config.disableUpdate = draft.autoUpdate ? nil : true
                try await configStore.save(config, at: installPath)
            } catch {
                // Exhaustive switch — compiler enforces all RunnerConfigStoreError cases
                // are handled (guaranteed by throws(RunnerConfigStoreError) on the protocol):
                // .readFailed / .decodeFailed arise from configStore.load(at:) above;
                // .writeFailed / .malformedExistingFile / .ioReadFailedDuringSave arise
                // from configStore.save(...).
                switch error {
                case .readFailed(let path, let underlying):
                    errors.append("Cannot read config at \(path)/.runner: \(underlying.localizedDescription)")
                case .decodeFailed(let path):
                    errors.append("Cannot decode config at \(path)/.runner")
                case .writeFailed(let path, let underlying):
                    errors.append("Cannot write config at \(path)/.runner: \(underlying.localizedDescription)")
                case .malformedExistingFile(let path):
                    // The existing .runner file is present but undecodable. Aborting rather
                    // than proceeding protects agent-managed keys (e.g. jitConfig) from
                    // being silently dropped during the read-modify-write merge.
                    errors.append("Cannot write config at \(path)/.runner: existing file is malformed and agent-managed keys would be lost")
                case .ioReadFailedDuringSave(let path, let underlying):
                    // The .runner file is known to exist but could not be read before the
                    // merge write. Proceeding would drop agent-managed keys — surface the
                    // error so the user can retry after the transient I/O condition clears.
                    errors.append("Cannot write config at \(path)/.runner: file is present but unreadable — agent-managed keys would be lost: \(underlying.localizedDescription)")
                }
            }
        }

        // MARK: Step 3 — Proxy files
        let proxyChanged = draft.proxyUrl != original.proxyUrl
            || draft.proxyUser != original.proxyUser
            || draft.proxyPassword != original.proxyPassword
        if proxyChanged {
            // Same early-return rationale as Step 2.
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write proxy files")
                return .failure(errors)
            }
            let proxyConfig = RunnerProxyConfig(
                url: draft.proxyUrl,
                user: draft.proxyUser,
                password: draft.proxyPassword
            )
            do {
                try await proxyStore.save(proxyConfig, at: installPath)
            } catch {
                switch error {
                case .writeFailed(let messages):
                    // Wrap the per-file internal messages into a single user-facing
                    // string rather than leaking raw DispatchQueue-level detail.
                    // The full detail is already logged inside RunnerProxyStore.
                    errors.append("Cannot write proxy files at \(installPath): \(messages.joined(separator: "; "))")
                }
            }
        }

        return errors.isEmpty ? .success : .failure(errors)
    }

    // MARK: - Private helpers

    /// Maps a `LabelsPrerequisiteError` to its human-readable error string.
    /// Extracted from `execute()` to keep cyclomatic complexity within the SwiftLint limit.
    private func labelsPrereqErrorMessage(_ error: LabelsPrerequisiteError) -> String {
        switch error {
        case .missingAgentId:
            return "Cannot save labels: missing agent ID"
        case .missingGitHubUrl:
            return "Cannot save labels: missing GitHub URL"
        case .invalidScope(let url):
            return "Cannot save labels: GitHub URL '\(url.absoluteString)' has no org/repo path — cannot derive API scope"
        }
    }

    /// Validates the prerequisites for the labels API call and extracts the scope string.
    ///
    /// Delegates path extraction to the canonical `scopeFromUrl(_:)` in
    /// `GitHubURLHelpers` (F-52), replacing the previous inline `pathComponents` slice.
    ///
    /// - Returns: `.success((agentId, scope))` when both fields are present;
    ///   `.failure(LabelsPrerequisiteError)` identifying the first missing field.
    /**
     Checks that the runner has a valid agent ID and GitHub URL, and derives the scope from the URL.
     
     - Parameter runner: The `RunnerModel` containing the runner data.
     - Returns: A `Result` containing a tuple `(Int, String)` where the first element is the agent ID and the second is the scope string, or a `LabelsPrerequisiteError` on failure.
     */
    private func labelsPrerequisite(
        runner: borrowing RunnerModel
    ) -> Result<(Int, String), LabelsPrerequisiteError> {
        guard let agentId = runner.agentId else { return .failure(.missingAgentId) }
        guard let url = runner.gitHubUrl else { return .failure(.missingGitHubUrl) }
        guard let scope = scopeFromUrl(url) else { return .failure(.invalidScope(url)) }
        return .success((agentId, scope))
    }
}
