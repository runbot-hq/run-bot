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
    case syntheticEmpty(stepName: String, reason: String)
    /// Network failure, ZIP parse failure, or subprocess failure.
    case fetchFailed(reason: String)

    /// The log text to display, or nil if there is nothing to show.
    public var text: String? {
        switch self {
        case .slice(let content), .flatBlobFallback(let content): return content
        case .syntheticEmpty, .fetchFailed: return nil
        }
    }

    /// True when this result represents a step that was intentionally skipped by the runner
    /// (as opposed to a fetch failure or a step that ran but produced no output).
    /// StepLogView uses this to render a neutral “Step skipped” headline instead of
    /// the error-toned “No output recorded” headline.
    public var isSkipped: Bool {
        guard case .syntheticEmpty(_, let reason) = self else { return false }
        return reason.hasPrefix("This step was skipped")
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
    /// Session-level LRU cache (L2 memory) shared across all `fetchStepLog` calls.
    /// Supersedes the old single-entry `zipCache` as the durable in-process layer.
    let zipLRUCache: ZIPLRUCache
    /// Persistent disk cache (L3) — survives app restarts.
    let diskZIPCache: DiskZIPCache
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
    ///   - zipLRUCache: Session-level LRU (L2). Defaults to a fresh instance; inject in tests.
    ///   - diskZIPCache: Persistent disk cache (L3). Defaults to a fresh instance; inject in tests.
    ///   - zipExtractor: Defaults to the real `/usr/bin/unzip`-based path.
    ///     Pass a custom closure in tests to bypass subprocess spawning.
    public init(
        transport: any GitHubTransportProtocol = currentTransport,
        zipLRUCache: ZIPLRUCache = ZIPLRUCache(),
        diskZIPCache: DiskZIPCache = DiskZIPCache(),
        zipExtractor: ZipExtractor? = nil
    ) {
        self.transport = transport
        self.zipLRUCache = zipLRUCache
        self.diskZIPCache = diskZIPCache
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
                    switch await unzipLogsTyped(data) {
                    case .success(let files):
                        return files
                    case .processFailed(let exitCode):
                        log("fetchActionLogs › run \(runID) — unzip exited \(exitCode)", category: .services)
                        return []
                    case .ioError:
                        log("fetchActionLogs › run \(runID) — unzip I/O error", category: .services)
                        return []
                    }
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
    /// The ZIP is cached in the LRU + disk layers keyed by `runID`. Subsequent calls for
    /// steps in the same job (same `runID`) cost zero network calls.
    ///
    /// ## Fallback
    /// When the ZIP contains no per-step files for the requested job, falls back to the existing
    /// flat blob + `parseStepLog` path and returns `.flatBlobFallback`. This keeps the old
    /// heuristic path alive as a degraded path without deleting it.
    ///
    /// - Parameters:
    ///   - runID: The GitHub workflow run ID (from `job.runID`).
    ///   - startedAt: Raw ISO 8601 start string (reserved for future use — currently unused in cache key).
    ///   - jobID: The GitHub Actions job ID used for the flat-blob fallback path.
    ///   - jobName: The job display name (from `job.name`). Sanitised before ZIP lookup.
    ///   - step: The `GitHubStep` whose log is requested.
    ///   - scope: The `owner/repo` string identifying the repository.
    ///   - isCompleted: Whether the run has completed. When `false`, the disk cache
    ///     write is skipped to avoid persisting a partial ZIP for an in-progress run.
    /// - Returns: A `StepLogResult` — never silent about failure or wrong content.
    public func fetchStepLog(
        runID: Int,
        startedAt: String?,
        jobID: Int,
        jobName: String,
        step: GitHubStep,
        scope: String,
        isCompleted: Bool = true
    ) async -> StepLogResult {
        guard scope.contains("/") else {
            log("fetchStepLog › invalid scope '\(scope)' — must be owner/repo", category: .services)
            return .fetchFailed(reason: "This run does not have a valid owner/repo scope, so the step log request could not be built.")
        }

        // Cache lookup — three-layer: LRU → disk → network. Returns raw ZIP Data.
        let fetchStart = ContinuousClock.now
        log(
            "fetchStepLog › runID=\(runID) jobName='\(jobName)' sanitised='\(sanitizeJobNameForZIP(jobName))' step=\(step.number) '\(step.name)' scope='\(scope)'",
            category: .services
        )
        let zipData: Data
        let zipFromCache: Bool
        switch await loadZipFiles(runID: runID, scope: scope, isCompleted: isCompleted) {
        case .hit(let data): zipData = data; zipFromCache = true
        case .miss(let data): zipData = data; zipFromCache = false
        case .failed(let result): return result
        }
        // Unzip lazily here — one entry at a time, only when the user taps a step.
        // If extraction fails and the data came from the network (not a cache hit),
        // evict it from both caches so a malformed download cannot loop forever.
        guard let extraction = await extractZip(zipData, runID: runID) else {
            if !zipFromCache {
                await zipLRUCache.evict(runID)
                await diskZIPCache.evict(runID: runID)
                log("fetchStepLog › evicted bad ZIP for runID=\(runID) from LRU + disk after extraction failure", category: .services)
            }
            return .fetchFailed(reason: "GitHub returned the run log archive, but macOS could not extract it (unzip exit code or I/O error).")
        }
        let allFiles = extraction.files
        log("fetchStepLog › allFiles (\(allFiles.count)): [\(allFiles.map { $0.name }.joined(separator: ", "))]", category: .services)

        // Exclude top-level blob files. Only entries with a "/" in the name are per-step
        // slices (e.g. "release/2_Checkout.txt" → name "release/2_Checkout"). Top-level
        // entries like a hypothetical root-level `.txt` file are filtered here.
        // `logs.zip` is already excluded in `unzipLogsTyped` (extension + explicit URL guard).
        // Keep only per-step entries (must contain "/") and strip macOS AppleDouble
        // metadata entries that the system zip tool injects under __MACOSX/.
        // The __MACOSX filter is also applied in unzipLogsTyped (filesystem layer) but
        // repeated here as defence-in-depth for stub-injected entries in tests and any
        // future extractor that doesn't strip them at source.
        let stepFiles = allFiles.filter { $0.name.contains("/") && !$0.name.hasPrefix("__MACOSX/") }
        let sanitised = sanitizeJobNameForZIP(jobName)
        let hasStepFiles = stepFiles.contains {
            $0.name.hasPrefix("\(sanitised)/") && !$0.name.hasSuffix("/system")
        }
        log("fetchStepLog › stepFiles (\(stepFiles.count)): [\(stepFiles.map { $0.name }.joined(separator: ", "))] hasStepFiles=\(hasStepFiles) sanitised='\(sanitised)'", category: .services)

        guard hasStepFiles else {
            guard let result = await flatBlobFallback(jobID: jobID, scope: scope, step: step, runID: runID) else {
                return .fetchFailed(reason: "Request was cancelled before flat-blob fallback could complete.")
            }
            return result
        }

        let prefix = "\(sanitised)/\(step.number)_"
        // Primary match: case-sensitive prefix (matches well-formed ZIP entries).
        // Fallback: case-insensitive prefix for enterprise instances where the server
        // may produce a different-cased folder name than the API job name.
        let prefixLower = prefix.lowercased()
        guard let match = stepFiles.first(where: { $0.name.hasPrefix(prefix) })
                       ?? stepFiles.first(where: { $0.name.lowercased().hasPrefix(prefixLower) })
        else {
            return stepMissResult(
                step: step, prefix: prefix, jobName: jobName,
                sanitised: sanitised, runID: runID, stepFiles: stepFiles
            )
        }

        let cleaned = cleanLogText(match.text)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log(
                "fetchStepLog › step \(step.number) '\(step.name)' job '\(jobName)' run \(runID) " +
                "— file '\(match.name)' found but content is empty after cleaning",
                category: .services
            )
            return .syntheticEmpty(
                stepName: step.name,
                reason: "The matching step log file was found (\(match.name)), but it was empty after cleanup."
            )
        }
        let fetchedTotal = fetchStart.duration(to: .now)
        log(
            "fetchStepLog › ✓ step \(step.number) '\(step.name)' job '\(jobName)' run \(runID) " +
            "— matched '\(match.name)' (\(cleaned.utf8.count) bytes) totalElapsed=\(fetchedTotal)",
            category: .services
        )
        return .slice(content: cleaned)
    }

    // MARK: - Private helpers

    /// Typed result from the cache/network pipeline used by `fetchStepLog`.
    /// Values are raw ZIP `Data`; unzipping happens in `fetchStepLog` after this returns.
    private enum ZipLoadResult {
        /// Raw ZIP bytes returned from a cache layer — no network call was made.
        case hit(Data)
        /// Raw ZIP bytes freshly downloaded — both cache layers have been updated.
        case miss(Data)
        /// A network or I/O failure occurred; the associated value is the terminal result.
        case failed(StepLogResult)
    }

    /// Extracts ZIP `Data` via `zipExtractor` and logs diagnostic info.
    ///
    /// Returns the extracted files on success, or a `StepLogResult` error on failure.
    private func extractZip(
        _ zipData: Data,
        runID: Int
    ) async -> (files: [(name: String, text: String)], error: StepLogResult?)? {
        let unzipStart = ContinuousClock.now
        switch await zipExtractor(zipData) {
        case .success(let files):
            let unzipDuration = unzipStart.duration(to: .now)
            let stepCount = files.filter { $0.name.contains("/") }.count
            log(
                "fetchStepLog › ZIP extracted \(files.count) file(s) for run \(runID) " +
                "(\(stepCount) with step-prefix '/') in \(unzipDuration)",
                category: .services
            )
            if stepCount == 0 {
                let names = files.map(\.name).joined(separator: ", ")
                log(
                    "fetchStepLog › ZIP has no per-step files for run \(runID) — " +
                    "all entries: [\(names.isEmpty ? "<empty archive>" : names)]",
                    category: .services
                )
            }
            return (files, nil)
        case .processFailed(let exitCode):
            let unzipDuration = unzipStart.duration(to: .now)
            log("fetchStepLog › unzip failed for run \(runID) — exit code \(exitCode) after \(unzipDuration)", category: .services)
            return nil
        case .ioError:
            let unzipDuration = unzipStart.duration(to: .now)
            log("fetchStepLog › I/O error writing or reading ZIP tmp dir for run \(runID) after \(unzipDuration)", category: .services)
            return nil
        }
    }

    /// Performs the flat-blob fallback when the ZIP contains no per-step files.
    /// Returns nil if the request was cancelled.
    private func flatBlobFallback(
        jobID: Int,
        scope: String,
        step: GitHubStep,
        runID: Int
    ) async -> StepLogResult? {
        log("fetchStepLog › no step files for job — attempting flat-blob fallback via fetchJobLog jobID=\(jobID)", category: .services)
        guard !Task.isCancelled else {
            log("fetchStepLog › cancelled before flat-blob fallback for job \(jobID)", category: .services)
            return .fetchFailed(reason: "Request was cancelled before flat-blob fallback could complete.")
        }
        let blobStart = ContinuousClock.now
        guard let raw = await fetchJobLog(jobID: jobID, scope: scope) else {
            log("fetchStepLog › flat-blob fallback also failed for job \(jobID) scope '\(scope)' after \(blobStart.duration(to: .now))", category: .services)
            return .fetchFailed(reason: "GitHub did not provide per-step log files for this job, and the fallback full-job log request also failed.")
        }
        let blobDuration = blobStart.duration(to: .now)
        guard !Task.isCancelled else {
            log("fetchStepLog › cancelled after flat-blob download for job \(jobID) (\(raw.utf8.count) bytes downloaded in \(blobDuration))", category: .services)
            return .fetchFailed(reason: "Request was cancelled after flat-blob download but before result could be returned.")
        }
        let parsed = parseStepLog(raw, stepName: step.name, stepNumber: step.number, logger: transport.logger)
        log("fetchStepLog › flat-blob fallback result: parsed=\(parsed != nil) rawBytes=\(raw.utf8.count) elapsed=\(blobDuration)", category: .services)
        if parsed == nil {
            log("fetchStepLog › parseStepLog returned nil for step \(step.number) '\(step.name)' job \(jobID) run \(runID) — serving full raw job log via flatBlobFallback", category: .services)
        }
        return .flatBlobFallback(content: parsed ?? cleanLogText(raw))
    }

    /// Fetches and caches raw ZIP `Data` for `runID` using a three-layer lookup:
    /// 1. LRU memory cache (`ZIPLRUCache`) — zero I/O
    /// 2. Disk cache (`DiskZIPCache`) — zero network
    /// 3. Network download — backfills both caches with raw `Data` on success
    ///
    /// Unzipping is **not** performed here. Callers (`fetchStepLog`) extract lazily
    /// after this method returns, so the cache only stores raw bytes.
    private func loadZipFiles(
        runID: Int,
        scope: String,
        isCompleted: Bool
    ) async -> ZipLoadResult {
        // Layer 1: LRU memory cache
        if let cached = await zipLRUCache.get(runID) {
            log(
                "fetchStepLog › LRU HIT runID=\(runID) — \(cached.count) byte(s)",
                category: .services
            )
            return .hit(cached)
        }
        // Layer 2: Disk cache
        if let cached = await diskZIPCache.get(runID: runID) {
            log(
                "fetchStepLog › DISK HIT runID=\(runID) — \(cached.count) byte(s), populating LRU",
                category: .services
            )
            await zipLRUCache.set(runID, zip: cached)
            return .hit(cached)
        }
        // Layer 3: Network
        let downloadStart = ContinuousClock.now
        log(
            "fetchStepLog › cache MISS runID=\(runID) — downloading ZIP",
            category: .services
        )
        guard let data = await transport.raw("repos/\(scope)/actions/runs/\(runID)/logs") else {
            log("fetchStepLog › network failure fetching ZIP for run \(runID) scope '\(scope)' after \(downloadStart.duration(to: .now))", category: .services)
            return .failed(.fetchFailed(reason: "Could not download the run log archive from GitHub."))
        }
        let downloadDuration = downloadStart.duration(to: .now)
        log("fetchStepLog › ZIP downloaded \(data.count) bytes for run \(runID) in \(downloadDuration)", category: .services)
        // Backfill both caches with raw bytes. Extraction is deferred to the caller.
        await zipLRUCache.set(runID, zip: data)
        await diskZIPCache.set(runID: runID, zip: data, isCompleted: isCompleted)
        return .miss(data)
    }

    /// Returns the `.syntheticEmpty` result for a step whose ZIP entry is missing,
    /// after logging the available files for diagnosis.
    ///
    /// Returns the informational skipped-step variant when `step.stepConclusion == .skipped`,
    /// mirroring `gh`'s silent `continue` for steps that genuinely have no ZIP entry.
    private func stepMissResult(
        step: GitHubStep,
        prefix: String,
        jobName: String,
        sanitised: String,
        runID: Int,
        stepFiles: [(name: String, text: String)]
    ) -> StepLogResult {
        let available = stepFiles
            .filter { $0.name.hasPrefix("\(sanitised)/") }
            .map { $0.name }
            .joined(separator: ", ")
        log(
            "fetchStepLog › no file matching prefix '\(prefix)' for step \(step.number) '\(step.name)' " +
            "job '\(jobName)' (sanitised: '\(sanitised)') run \(runID) — " +
            "files for this job: [\(available.isEmpty ? "<none>" : available)]",
            category: .services
        )
        if step.stepConclusion == .skipped {
            log(
                "fetchStepLog › step \(step.number) '\(step.name)' was skipped — no ZIP entry expected",
                category: .services
            )
            return .syntheticEmpty(stepName: step.name, reason: "This step was skipped and produced no log output.")
        }
        return .syntheticEmpty(
            stepName: step.name,
            reason: available.isEmpty
                ? "This job had step log files, but none matched step \(step.number)."
                : "This job had step log files, but none matched step \(step.number). Available files for this job: \(available). Tried prefix: '\(prefix)' (sanitised job name: '\(sanitised)')."
        )
    }
}

// MARK: - Job name sanitisation for ZIP lookup

/// Sanitises a GitHub job name for use as a ZIP folder prefix.
///
/// Applies three rules in order, matching the logic in `getJobNameForLogFilename` in the
/// `gh` CLI ([`logs.go`](https://github.com/cli/cli/blob/trunk/pkg/cmd/run/view/logs.go))
/// and the C# server's `GetJobNameForLogFilename`:
/// 1. Strip characters invalid in Windows file paths — the C# server (which writes the ZIP)
///    strips `/`, `:`, `"`, `*`, `?`, `<`, `>`, `|`. Not stripping these causes a prefix
///    mismatch when a job name contains any of them and the server has already removed them
///    from the ZIP folder name.
/// 2. Truncate to **90 UTF-16 code units** — the GitHub server (C#) truncates using
///    `String.Substring(0, 90)` which counts UTF-16 `Char` objects. Swift `.count` counts
///    Unicode scalars, not UTF-16 code units — emoji and CJK characters truncate at a
///    different offset without this step.
/// 3. Trim leading/trailing whitespace/newlines — the C# server calls `.Trim()` after truncation
///    (and the `gh` CLI does `strings.TrimSpace`). Truncation can expose trailing
///    whitespace that was previously interior.
func sanitizeJobNameForZIP(_ name: String) -> String {
    // Strip the full set of characters the C# server considers invalid in a Windows path.
    // The `gh` CLI only strips `/` and `:` explicitly, but the server strips all of these.
    // Stripping only `/` and `:` causes silent misses when job names contain `"`, `*`, etc.
    let stripped = name
        .replacingOccurrences(of: "/", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "*", with: "")
        .replacingOccurrences(of: "?", with: "")
        .replacingOccurrences(of: "<", with: "")
        .replacingOccurrences(of: ">", with: "")
        .replacingOccurrences(of: "|", with: "")
    guard stripped.utf16.count > 90 else { return stripped.trimmingCharacters(in: .whitespacesAndNewlines) }
    var units = Array(stripped.utf16.prefix(90))
    // Guard against splitting a surrogate pair at the 90-unit boundary.
    // Swift strings are always well-formed, so surrogates only appear as
    // high+low pairs. The only reachable split is a high surrogate at position
    // 89 (0xD800–0xDBFF) whose low partner was at 90 and is now dropped —
    // remove the dangling high to keep the output valid.
    // A lone low surrogate (0xDC00–0xDFFF) at the boundary cannot arise from a
    // well-formed Swift String: the high surrogate at 88 would still be present,
    // keeping the pair intact. Malformed UTF-16 fed via String(decoding:as:UTF16.self)
    // is normalised to U+FFFD before we ever see it, so no guard is needed.
    if let last = units.last, (0xD800...0xDBFF).contains(last) {
        units.removeLast()
    }
    // Mirror the C# server's `.Trim()` call (and the gh CLI's `strings.TrimSpace`) which
    // both trim the result after truncation. Truncation can expose trailing whitespace
    // that was previously interior.
    return String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - ZIP extraction (uses /usr/bin/unzip — always available on macOS)

/// Extracts all `.txt` files from a ZIP blob and returns `(name, text)` pairs.
///
/// Writes the ZIP to a unique temporary directory, runs `/usr/bin/unzip -q` via
/// `ProcessRunner.runAsync`, then enumerates the output directory for `.txt` files.
/// The temporary directory is always removed on return via `defer`.
///
/// - Parameter zipData: Raw ZIP archive bytes as returned by the GitHub logs API.
/// - Returns: An array of `(name, text)` tuples where `name` is the archive-relative
///   path without the `.txt` extension (e.g. `"release/1_Build"` for `release/1_Build.txt`)
///   and `text` is the file content. Returns `[]` if the write, unzip, or enumeration
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
/// `fetchStepLog` can map it to `.fetchFailed(reason: "Invalid repository scope: expected owner/repo.")` rather than `.syntheticEmpty`).
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
    // Exit code 0 = success. Exit code 1 = success with warnings (e.g. extra bytes
    // prepended to the ZIP — which GitHub's log API occasionally produces). Only
    // exit code 2 and above indicate a genuine extraction failure.
    guard result.exitCode <= 1 else { return .processFailed(exitCode: result.exitCode) }
    guard let enumerator = fileManager.enumerator(at: tmp, includingPropertiesForKeys: nil) else { return .ioError }
    // Keep only .txt files and exclude the archive itself.
    // `logs.zip` is written into `tmp` before extraction so the enumerator sees it;
    // the `.pathExtension == "txt"` check is the primary guard ("zip" ≠ "txt"), and
    // the explicit URL comparison is belt-and-suspenders against a future rename of
    // the temp file to a .txt name.
    let zipFileResolved = zipFile.resolvingSymlinksInPath()
    let txtURLs = enumerator.compactMap { $0 as? URL }.filter {
        $0.pathExtension == "txt"
        && $0.resolvingSymlinksInPath() != zipFileResolved
        // macOS's zip tool injects __MACOSX/ AppleDouble metadata entries into every
        // archive it creates. These are never valid step log files and would pollute
        // allFiles, skew stepCount, and add noise to diagnostic logs.
        && !$0.path.contains("/__MACOSX/")
    }
    var results: [(name: String, text: String)] = []
    // Resolve symlinks on the tmp prefix so that the /tmp → /private/tmp alias
    // on macOS does not cause the prefix-stripping below to silently no-op,
    // leaving absolute paths (e.g. "/privaterelease/2_Checkout") in the names.
    let tmpResolved = tmp.resolvingSymlinksInPath().path
    for url in txtURLs {
        // Strip the tmp directory prefix to get the archive-relative path, then
        // drop the .txt extension. Using NSString.deletingPathExtension rather than
        // URL(fileURLWithPath:).deletingPathExtension().path avoids the leading-slash
        // bug: URL(fileURLWithPath:) treats its argument as absolute, prepending "/"
        // to relative strings and breaking the hasPrefix("jobName/") lookup downstream.
        let resolved = url.resolvingSymlinksInPath().path
        let relative = resolved.replacingOccurrences(of: tmpResolved + "/", with: "")
        let name = (relative as NSString).deletingPathExtension
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            results.append((name: name, text: text))
        }
    }
    return .success(results)
}
