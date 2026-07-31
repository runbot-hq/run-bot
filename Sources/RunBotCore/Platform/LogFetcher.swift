// LogFetcher.swift
// RunBotCore
import Foundation
import GitHubClient
import os

// MARK: - Filesystem path constants

/// Absolute path to the system `unzip` binary, always present on macOS.
private let unzipBinaryPath = "/usr/bin/unzip" // NOSONAR — fixed OS path

// MARK: - StepLogResult

/// Typed result from step log extraction.
/// Every case is distinct — wrong content can never silently look like correct content.
public enum StepLogResult: Equatable, Sendable {
    /// ZIP file found and matched by {sanitisedJobName}/{stepNumber}_*.txt.
    case slice(content: String)
    /// ZIP contained no per-step files for this job — flat blob used instead.
    /// StepLogView MUST render a visible degradation notice for this case.
    case flatBlobFallback(content: String)
    /// Step produced no output (ZIP file present but empty, or step not found).
    case syntheticEmpty(stepName: String)
    /// Network failure, ZIP parse failure, or subprocess failure.
    case fetchFailed

    /// The log text to display, or nil if there is nothing to show.
    public var text: String? {
        switch self {
        case .slice(let content), .flatBlobFallback(let content): return content
        case .syntheticEmpty, .fetchFailed: return nil
        }
    }
}

// MARK: - UnzipResult

/// Typed result from `unzipLogs(_:)` — distinguishes subprocess failure from empty archive.
public enum UnzipResult: Sendable {
    /// ZIP extracted successfully; contains (relative path, text) pairs for every `.txt` file found.
    case success([(name: String, text: String)])
    /// `/usr/bin/unzip` exited with a non-zero status. The associated value is the raw exit code.
    case processFailed(exitCode: Int32)
    /// A filesystem operation failed (directory creation, file write, or enumeration).
    case ioError
}

/// A closure that extracts a ZIP archive (`Data`) into named text file entries.
/// The default implementation spawns `/usr/bin/unzip`; tests inject a stub.
public typealias ZipExtractor = @Sendable (Data) async -> UnzipResult

// MARK: - LogFetcher

/// Injectable fetcher for GitHub Actions job and workflow-run logs.
///
/// Wraps a `GitHubTransportProtocol` and exposes single-job and grouped-run log
/// fetching. All network access goes through the injected transport, making this
/// type testable without live network access.
///
/// ## Concurrency
///
/// `LogFetcher` is a `Sendable` struct — it holds a transport existential
/// that is safe for concurrent use. The public entry
/// points are `async` but do not carry `@concurrent` since they are called from
/// `Task.detached` contexts (not actor-isolated code paths).
public struct LogFetcher: Sendable {
    /// The injected GitHub transport used for all network access.
    private let transport: any GitHubTransportProtocol
    /// In-memory cache of ZIP file listings keyed by `"runID-startedAt"`. Populated on first
    /// fetch; subsequent taps in the same session cost zero network calls.
    /// Keyed by `runID-startedAt` (not `runID` alone) so re-runs of the same workflow
    /// do not return stale log files.
    private var zipCache: [String: [(name: String, text: String)]] = [:]
    /// Closure that extracts a ZIP archive into named text entries.
    /// Defaults to the real `unzipLogsTyped` subprocess path.
    /// Tests inject a stub that returns pre-built tuples directly, avoiding any
    /// filesystem or process access (which the test sandbox blocks).
    var zipExtractor: ZipExtractor

    /// Creates a fetcher backed by the given transport.
    ///
    /// - Parameters:
    ///   - transport: Defaults to `currentTransport` — the live `@TaskLocal`
    ///     read path wired by `GitHubClient.init`. Tests can override via
    ///     `withTransport(_:operation:)` without touching any global.
    ///   - zipExtractor: Defaults to the real `/usr/bin/unzip`-based path.
    ///     Pass a custom closure in tests to bypass subprocess spawning.
    public init(
        transport: any GitHubTransportProtocol = currentTransport,
        zipExtractor: ZipExtractor? = nil
    ) {
        self.transport = transport
        self.zipExtractor = zipExtractor ?? { data in await unzipLogsTyped(data) }
    }

    // MARK: - Job log (plain text, 1 call)

    /// Fetches the full plain-text log for a single job.
    ///
    /// `/actions/jobs/{id}/logs` 302-redirects to a short-lived S3 URL; the transport follows it.
    /// Returns `nil` when `scope` is not in `owner/repo` form, the request fails,
    /// or the response body looks like a JSON error object (starts with `"{"`). 
    ///
    /// - Parameters:
    ///   - jobID: The GitHub Actions job ID.
    ///   - scope: The `owner/repo` string identifying the repository.
    /// - Returns: Plain-text log content, or `nil` on failure.
    public func fetchJobLog(jobID: Int, scope: String) async -> String? {
        guard scope.contains("/") else { return nil }
        guard let data = await transport.raw("repos/\(scope)/actions/jobs/\(jobID)/logs"),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("{") { return nil }
        return text
    }

    // MARK: - Action logs (ZIP per run, N calls)

    /// Fetches and concatenates all job logs for every run in a group.
    ///
    /// Issues one async task per run inside a `TaskGroup`, each retrieving a ZIP
    /// archive and extracting all `.txt` log files via `unzipLogs(_:)`. Results are
    /// collected and sorted by filename for stable ordering when names are unique.
    ///
    /// - Parameter group: The `WorkflowActionGroup` whose runs should be fetched.
    /// - Returns: A single concatenated string with `=== <name> ===` section headers,
    ///   or `nil` if `scope` is invalid, `runs` is empty, or all fetches fail.
    public func fetchActionLogs(group: WorkflowActionGroup) async -> String? {
        let scope = group.repo
        guard scope.contains("/") else { return nil }
        let runIDs = group.runs.map { $0.id }
        guard !runIDs.isEmpty else { return nil }

        let parts: [(name: String, text: String)] = await withTaskGroup(
            of: [(name: String, text: String)].self
        ) { taskGroup in
            for runID in runIDs {
                taskGroup.addTask {
                    guard let data = await transport.raw("repos/\(scope)/actions/runs/\(runID)/logs") else {
                        log("fetchActionLogs › run \(runID) — transport.raw returned nil, skipping", category: .services)
                        return []
                    }
                    return await unzipLogs(data)
                }
            }
            var collected: [(name: String, text: String)] = []
            for await batch in taskGroup {
                collected.append(contentsOf: batch)
            }
            return collected
        }

        guard !parts.isEmpty else { return nil }
        return parts
            .sorted { $0.name < $1.name }
            .map { "=== \($0.name) ===\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Step log via ZIP per-step files (root-cause fix for #2358)

    /// Fetches the log for a single step using the run-level ZIP archive.
    ///
    /// GitHub pre-splits the ZIP into per-step files named `{sanitisedJobName}/{stepNumber}_*.txt`.
    /// Every step — including synthetic steps (`Set up job`, `Post *`, `Complete job`) — gets
    /// its own file, making heuristic parsing unnecessary.
    ///
    /// ## Cache
    /// The ZIP is cached in `zipCache` keyed by `"runID-startedAt"`. Subsequent calls for
    /// steps in the same job (same `runID` + `startedAt`) cost zero network calls.
    ///
    /// ## Fallback
    /// When the ZIP contains no per-step files for the requested job, falls back to the existing
    /// flat blob + `parseStepLog` path and returns `.flatBlobFallback`. This keeps the old
    /// heuristic path alive as a degraded path without deleting it.
    ///
    /// - Parameters:
    ///   - runID: The GitHub workflow run ID (from `job.runID`).
    ///   - startedAt: Raw ISO 8601 start string used as cache-key discriminator (from `job.startedAt`).
    ///   - jobName: The job display name (from `job.name`). Sanitised before ZIP lookup.
    ///   - step: The `GitHubStep` whose log is requested.
    ///   - scope: The `owner/repo` string identifying the repository.
    /// - Returns: A `StepLogResult` — never silent about failure or wrong content.
    public mutating func fetchStepLog(
        runID: Int,
        startedAt: String?,
        jobID: Int,
        jobName: String,
        step: GitHubStep,
        scope: String
    ) async -> StepLogResult {
        guard scope.contains("/") else {
            log("fetchStepLog › invalid scope '\(scope)' — must be owner/repo", category: .services)
            return .fetchFailed
        }

        func clean(_ text: String) -> String { cleanLogText(text) }

        // Cache lookup
        let cacheKey = "\(runID)-\(startedAt ?? "")"
        let allFiles: [(name: String, text: String)]
        if let cached = zipCache[cacheKey] {
            allFiles = cached
        } else {
            guard let data = await transport.raw("repos/\(scope)/actions/runs/\(runID)/logs") else {
                log("fetchStepLog › network failure fetching ZIP for run \(runID) scope '\(scope)'", category: .services)
                return .fetchFailed
            }
            switch await zipExtractor(data) {
            case .success(let files):
                zipCache[cacheKey] = files
                allFiles = files
            case .processFailed(let exitCode):
                log("fetchStepLog › unzip failed for run \(runID) — exit code \(exitCode)", category: .services)
                return .fetchFailed
            case .ioError:
                log("fetchStepLog › I/O error writing or reading ZIP tmp dir for run \(runID)", category: .services)
                return .fetchFailed
            }
        }

        // Exclude top-level blob files (no '/' in name)
        let stepFiles = allFiles.filter { $0.name.contains("/") }

        // Check if ZIP has any per-step files for this job at all
        let sanitised = sanitizeJobNameForZIP(jobName)
        let hasStepFiles = stepFiles.contains { $0.name.hasPrefix("\(sanitised)/") }

        guard hasStepFiles else {
            // ZIP has no per-step files for this job — fall back to flat blob
            guard let raw = await fetchJobLog(jobID: jobID, scope: scope) else {
                log("fetchStepLog › flat-blob fallback also failed for job \(jobID) scope '\(scope)'", category: .services)
                return .fetchFailed
            }
            let parsed = parseStepLog(raw, stepName: step.name, stepNumber: step.number, logger: transport.logger)
            return .flatBlobFallback(content: parsed ?? clean(raw))
        }

        // Single prefix match: {sanitisedJobName}/{stepNumber}_*
        let prefix = "\(sanitised)/\(step.number)_"
        guard let match = stepFiles.first(where: { $0.name.hasPrefix(prefix) }) else {
            return .syntheticEmpty(stepName: step.name)
        }

        let cleaned = clean(match.text)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .syntheticEmpty(stepName: step.name)
        }
        return .slice(content: cleaned)
    }
}

// MARK: - Job name sanitisation for ZIP lookup

/// Sanitises a GitHub job name for use as a ZIP folder prefix.
///
/// Applies three rules in order, matching the logic in `getJobNameForLogFilename` in the
/// `gh` CLI ([`logs.go`](https://github.com/cli/cli/blob/trunk/pkg/cmd/run/view/logs.go)):
/// 1. Strip `/` — composite action jobs contain slashes in the API name.
/// 2. Strip `:` — reusable workflow jobs contain colons.
/// 3. Truncate to **90 UTF-16 code units** — the GitHub server (C#) truncates using
///    `String.Substring(0, 90)` which counts UTF-16 `Char` objects. Swift `.count` counts
///    Unicode scalars, not UTF-16 code units — emoji and CJK characters truncate at a
///    different offset without this step.
func sanitizeJobNameForZIP(_ name: String) -> String {
    var result = name
        .replacingOccurrences(of: "/", with: "")
        .replacingOccurrences(of: ":", with: "")
    let utf16 = result.utf16
    if utf16.count > 90,
       let endIndex = utf16.index(utf16.startIndex, offsetBy: 90, limitedBy: utf16.endIndex),
       let truncated = String(utf16[utf16.startIndex..<endIndex]) {
        result = truncated
    }
    return result
}

// MARK: - ZIP extraction (uses /usr/bin/unzip — always available on macOS)

/// Extracts all `.txt` files from a ZIP blob and returns `(name, text)` pairs.
///
/// Writes the ZIP to a unique temporary directory, runs `/usr/bin/unzip -q` via
/// `ProcessRunner.runAsync`, then enumerates the output directory for `.txt` files.
/// The temporary directory is always removed on return via `defer`.
///
/// The directory enumeration is materialised into an `[URL]` array *before* any
/// `await`, because `FileManager.DirectoryEnumerator.makeIterator` is unavailable
/// from async contexts (Swift concurrency restriction).
///
/// - Parameter zipData: Raw ZIP archive bytes as returned by the GitHub logs API.
/// - Returns: An array of `(name, text)` tuples where `name` is the archive-relative
///   path without the `.txt` extension (e.g. `"1_Build"` for `1_Build.txt`) and
///   `text` is the file content. Returns `[]` if the write, unzip, or enumeration
///   step fails.
func unzipLogs(_ zipData: Data) async -> [(name: String, text: String)] {
    switch await unzipLogsTyped(zipData) {
    case .success(let files): return files
    case .processFailed, .ioError: return []
    }
}

/// Typed variant of `unzipLogs` that distinguishes subprocess failure from an empty archive.
///
/// Returns `.processFailed(exitCode:)` when `/usr/bin/unzip` exits non-zero (so
/// `fetchStepLog` can map it to `.fetchFailed` rather than `.syntheticEmpty`).
/// Returns `.ioError` when the temp directory or ZIP file cannot be created.
func unzipLogsTyped(_ zipData: Data) async -> UnzipResult {
    let fileManager = FileManager.default
    let tmp = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let zipFile = tmp.appendingPathComponent("logs.zip")
    defer { try? fileManager.removeItem(at: tmp) }
    do {
        try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        try zipData.write(to: zipFile)
    } catch { return .ioError }
    let result = await ProcessRunner.runAsync(
        executableURL: URL(fileURLWithPath: unzipBinaryPath),
        arguments: ["-q", zipFile.path, "-d", tmp.path]
    )
    guard result.exitCode == 0 else { return .processFailed(exitCode: result.exitCode) }
    // Materialise the enumerator into a plain [URL] array before any suspension
    // point — FileManager.DirectoryEnumerator.makeIterator is unavailable from
    // async contexts (Swift concurrency restriction).
    guard let enumerator = fileManager.enumerator(at: tmp, includingPropertiesForKeys: nil) else { return .ioError }
    let txtURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "txt" }
    var results: [(name: String, text: String)] = []
    for url in txtURLs {
        let relative = url.path.replacingOccurrences(of: tmp.path + "/", with: "")
        let name = URL(fileURLWithPath: relative).deletingPathExtension().path
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            results.append((name: name, text: text))
        }
    }
    return .success(results)
}
