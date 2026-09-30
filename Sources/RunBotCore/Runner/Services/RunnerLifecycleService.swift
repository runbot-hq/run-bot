// RunnerLifecycleService.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - RunnerLifecycleService

/// Manages the macOS launchctl service lifecycle for locally-installed GitHub Actions runner agents.
///
/// Each runner is installed as a launchd agent via the runner's own `svc.sh` script.
/// This service drives the install → start, stop → uninstall, and full removal sequences,
/// delegating process execution to `ProcessRunner` and token fetching to the GitHub API.
public struct RunnerLifecycleService: RunnerLifecycleServiceProtocol {

    /// Creates a new `RunnerLifecycleService` instance.
    public init() {
        // Intentionally empty: stateless service holds no stored properties.
    }

    // MARK: - Start

    /// Installs and starts the launchd service for `runner` by running `svc.sh install` then `svc.sh start`.
    ///
    /// Returns `.corruptInstall` if either step detects a broken installation,
    /// `.success` if the start step exits 0, or `.failed` with the first non-empty
    /// output line otherwise.
    @discardableResult
    public func start(runner: RunnerModel) async -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        let gh = runner.gitHubUrl?.absoluteString ?? "nil"
        logStep("START", "called runner=\(runner.runnerName) installPath=\(ip) gitHubUrl=\(gh)")
        guard let path = runner.installPath else {
            logStep("START", "abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)
        let svcPath = dir.appendingPathComponent("svc.sh").path
        logStep("START", "svc.sh=\(svcPath) exists=\(FileManager.default.fileExists(atPath: svcPath)) executable=\(FileManager.default.isExecutableFile(atPath: svcPath))")

        logStep("START", "step1: svc.sh install")
        let (installOk, installOutput) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["install"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh install")
        logStep("START", "step1 done: ok=\(installOk) output=\(installOutput.prefix(300))")
        if isCorruptInstall(output: installOutput) {
            logStep("START", "RETURNING .corruptInstall after install step for \(runner.runnerName)")
            return .corruptInstall
        }

        logStep("START", "step2: svc.sh start")
        let (startOk, startOutput) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["start"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh start")
        logStep("START", "step2 done: ok=\(startOk) output=\(startOutput.prefix(300))")
        if isCorruptInstall(output: startOutput) {
            logStep("START", "RETURNING .corruptInstall after start step for \(runner.runnerName)")
            return .corruptInstall
        }
        if startOk {
            logStep("START", "RETURNING .success for \(runner.runnerName)")
            return .success
        }
        let msg = startOutput.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to start"
        logStep("START", "RETURNING .failed(\(msg)) for \(runner.runnerName)")
        return .failed(msg)
    }

    // MARK: - Stop

    /// Stops and uninstalls the launchd service for `runner` by running `svc.sh stop` then `svc.sh uninstall`.
    ///
    /// Returns `.corruptInstall` if either step detects a broken installation,
    /// `.success` if the stop step exits 0, or `.failed` with the first non-empty
    /// output line otherwise.
    ///
    /// - Note: The uninstall step (step 2) is best-effort — its exit code does not affect the
    ///   return value because a successful `svc.sh stop` is sufficient to take the runner offline.
    ///   A corrupt-install signal from `uninstallOutput` is still surfaced as `.corruptInstall`.
    @discardableResult
    public func stop(runner: RunnerModel) async -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        logStep("STOP", "called runner=\(runner.runnerName) installPath=\(ip)")
        guard let path = runner.installPath else {
            logStep("STOP", "abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)

        logStep("STOP", "step1: svc.sh stop")
        let (stopOk, stopOutput) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["stop"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh stop")
        logStep("STOP", "step1 done: ok=\(stopOk) output=\(stopOutput.prefix(300))")
        if isCorruptInstall(output: stopOutput) {
            logStep("STOP", "RETURNING .corruptInstall after stop step for \(runner.runnerName)")
            return .corruptInstall
        }

        logStep("STOP", "step2: svc.sh uninstall")
        let (_, uninstallOutput) = await runScriptWithOutput(
            // uninstall exit code is intentionally ignored — best-effort after a successful stop.
            executableName: "svc.sh", arguments: ["uninstall"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh uninstall")
        logStep("STOP", "step2 done: output=\(uninstallOutput.prefix(300))")
        if isCorruptInstall(output: uninstallOutput) {
            logStep("STOP", "RETURNING .corruptInstall after uninstall step for \(runner.runnerName)")
            return .corruptInstall
        }

        if stopOk {
            logStep("STOP", "RETURNING .success for \(runner.runnerName)")
            return .success
        }
        let msg = stopOutput.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to stop"
        logStep("STOP", "RETURNING .failed(\(msg)) for \(runner.runnerName)")
        return .failed(msg)
    }

    // MARK: - Remove

    /// Fully removes a runner: uninstalls the launchd service, deregisters it from GitHub via
    /// `config.sh remove` (falling back to the API DELETE endpoint if the script fails),
    /// deletes the install directory, and removes the LaunchAgent plist.
    ///
    /// Return value priority (highest first):
    /// - `.corruptInstall` — `config.sh` failed with a corrupt-install signal (missing/non-executable
    ///   script, or known corruption string in output). Returned regardless of whether the API DELETE
    ///   fallback subsequently succeeded; the broken local install still needs user attention.
    /// - `.success` — `config.sh` exited 0 (the only path that does not go through the fallback).
    /// - `.failed` — both `config.sh` and the API DELETE fallback failed; deregistration incomplete.
    ///
    /// - Note: Local file cleanup (install directory + LaunchAgent plist) is performed whenever
    ///   deregistration succeeds (either path). If both paths fail, no local files are deleted
    ///   so the user can retry.
    @discardableResult
    public func remove(runner: RunnerModel) async -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        let gh = runner.gitHubUrl?.absoluteString ?? "nil"
        logStep("REMOVE", "called runner=\(runner.runnerName) installPath=\(ip) gitHubUrl=\(gh)")
        guard let path = runner.installPath else {
            logStep("REMOVE", "abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)

        // Step 1 is best-effort and its result is deliberately NOT propagated:
        // `svcOk` is logged and then only re-reported in the final summary line. A
        // runner whose LaunchAgent was already unloaded (or never installed) fails
        // here harmlessly, and blocking deregistration on that would strand the
        // runner as registered on GitHub with no local way to remove it.
        // ❌ Do not "fix" this by returning early when svcOk is false.
        logStep("REMOVE", "step1: svc.sh uninstall")
        let (svcOk, _) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["uninstall"],
            workingDirectory: dir, timeout: 30, logTag: "svc.sh uninstall")
        logStep("REMOVE", "step1 result=\(svcOk) (non-fatal)")

        guard let gitHubUrl = runner.gitHubUrl else {
            logStep("REMOVE", "abort — no gitHubUrl on runner \(runner.runnerName)")
            return .failed("GitHub URL unknown")
        }
        // Hard-fail when no scope can be derived: passing a bare URL string
        // (e.g. https://github.com) to fetchRemovalToken / deleteRunnerByID
        // causes a silent API failure. Surfacing the error here gives the caller
        // a clear signal rather than a confusing "failed to fetch removal token".
        guard let scopeString = scopeFromUrl(gitHubUrl) else {
            logStep("REMOVE", "abort — cannot derive scope from gitHubUrl=\(gitHubUrl.absoluteString) for \(runner.runnerName)")
            return .failed("Cannot derive scope from GitHub URL '\(gitHubUrl.absoluteString)'")
        }

        logStep("REMOVE", "step2: fetching removal token for scope=\(scopeString)")
        guard let token = await fetchRemovalToken(scope: scopeString) else {
            logStep("REMOVE", "abort — fetchRemovalToken returned nil for scope=\(scopeString)")
            return .failed("Failed to fetch removal token")
        }
        logStep("REMOVE", "step2: got token len=\(token.count)")

        logStep("REMOVE", "step3: config.sh remove --token <token> in \(path)")
        let configPath = dir.appendingPathComponent("config.sh").path
        let (cfgOk, cfgOutput) = await runScriptWithOutput(
            executableName: "config.sh", arguments: ["remove", "--token", token],
            workingDirectory: dir, timeout: 30, logTag: "config.sh remove")
        logStep("REMOVE", "step3 result=\(cfgOk) for \(runner.runnerName)")

        let failureResult = await handleConfigRemoveFailure(
            cfgOk: cfgOk,
            cfgOutput: cfgOutput,
            configPath: configPath,
            scopeString: scopeString,
            agentID: runner.agentId
        )
        let removeOk = failureResult.removeOk
        let isCorrupt = failureResult.isCorrupt

        if removeOk {
            logStep("REMOVE", "step4: deleting install dir \(path)")
            do {
                try FileManager.default.removeItem(atPath: path)
                logStep("REMOVE", "step4: deleted \(path)")
            } catch {
                logStep("REMOVE", "step4: failed to delete dir \(path): \(error)")
            }
            deleteLaunchAgentPlist(for: runner.runnerName)
        } else {
            logStep("REMOVE", "step4: skipping local cleanup — deregistration failed for \(runner.runnerName)")
        }
        logStep("REMOVE", "done: svcOk=\(svcOk) cfgOk=\(cfgOk) removeOk=\(removeOk) isCorrupt=\(isCorrupt) for \(runner.runnerName)")

        // isCorrupt takes priority: surface the broken-install signal to the caller even when the
        // API DELETE fallback succeeded. A corrupt local install still needs user attention.
        if isCorrupt { return .corruptInstall }
        if removeOk { return .success }
        return .failed("Failed to deregister runner \(runner.runnerName)")
    }

    /// Handles a failed `config.sh remove` call, including corrupt-install detection and
    /// the API DELETE fallback when an `agentID` is available.
    ///
    /// - Returns: A tuple containing the final deregistration result and whether the local
    ///   install appears corrupt.
    private func handleConfigRemoveFailure(
        cfgOk: Bool,
        cfgOutput: String,
        configPath: String,
        scopeString: String,
        agentID: Int?
    ) async -> (removeOk: Bool, isCorrupt: Bool) {
        guard !cfgOk else { return (true, false) }
        let lowerCfgOutput = cfgOutput.lowercased()
        let configExecutable = FileManager.default.isExecutableFile(atPath: configPath)
        let isCorrupt = !configExecutable
            || lowerCfgOutput.contains("no such file or directory")
            || lowerCfgOutput.contains("install is corrupt")
            || lowerCfgOutput.contains("must run from runner root")
        logStep("REMOVE", "step3b: config.sh failed isCorrupt=\(isCorrupt) configExecutable=\(configExecutable) — trying API DELETE fallback")
        guard let agentID else {
            logStep("REMOVE", "step3b: no agentId available — cannot use API DELETE fallback")
            return (false, isCorrupt)
        }
        logStep("REMOVE", "step3b: calling deleteRunnerByID scope=\(scopeString) agentId=\(agentID)")
        let apiOk = await deleteRunnerByID(scope: scopeString, runnerID: agentID)
        logStep("REMOVE", "step3b: deleteRunnerByID result=\(apiOk)")
        return (apiOk, isCorrupt)
    }

    // MARK: - Corrupt install detection

    /// Returns `true` if `output` contains a string that indicates the runner installation is corrupt
    /// (e.g. the runner was moved or partially uninstalled outside the app).
    private func isCorruptInstall(output: String) -> Bool {
        let lower = output.lowercased()
        let result = lower.contains("must run from runner root") || lower.contains("install is corrupt")
        logStep("isCorruptInstall", "result=\(result) for output prefix=\(output.prefix(100))")
        return result
    }

    // MARK: - LaunchAgent plist cleanup

    /// Removes any LaunchAgent plist file in `~/Library/LaunchAgents` whose name matches
    /// the pattern `actions.runner.*.<runnerName>`. Called as the final cleanup step in `remove()`.
    private func deleteLaunchAgentPlist(for runnerName: String) {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: laDir, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            if filename.hasPrefix("actions.runner") && filename.hasSuffix("." + runnerName) {
                try? FileManager.default.removeItem(at: url)
                logStep("deleteLaunchAgentPlist", "deleted \(url.path)")
            }
        }
    }

    // MARK: - Script runner

    /// Runs a shell script relative to `workingDirectory` and returns `(exitCode == 0, combined output)`.
    ///
    /// Thin wrapper around `ProcessRunner.runAsync` that resolves the executable by name within the
    /// runner's install directory, guards against non-executable files, and merges stderr into stdout.
    private func runScriptWithOutput(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) async -> (Bool, String) {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let execPath = executableURL.path
        let isExec = FileManager.default.isExecutableFile(atPath: execPath)
        logStep("runScript [\(logTag)]", "execPath=\(execPath) executable=\(isExec) args=\(arguments.filter { $0.hasPrefix("--") || $0.count <= 20 }) cwd=\(workingDirectory.path)")
        guard isExec else {
            logStep("runScript [\(logTag)]", "ABORT not executable")
            return (false, "")
        }
        let result = await ProcessRunner.runAsync(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            mergeStderr: true,
            timeout: timeout
        )
        logStep("runScript [\(logTag)]", "exit=\(result.exitCode) output=\(result.output.prefix(500))")
        return (result.exitCode == 0, result.output)
    }

    // MARK: - Logging helper

    /// Emits a structured log line in the format `RunnerLifecycle > <tag>: <message>`.
    /// Centralises the prefix so individual methods stay concise.
    private func logStep(_ tag: String, _ message: String) {
        log("RunnerLifecycle > \(tag): \(message)", category: .runner)
    }
}
