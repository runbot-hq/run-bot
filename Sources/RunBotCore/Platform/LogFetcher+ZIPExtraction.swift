// LogFetcher+ZIPExtraction.swift
// RunBotCore
import Foundation

// MARK: - Filesystem path constants

/// Absolute path to the system `unzip` binary, always present on macOS.
private let unzipBinaryPath = "/usr/bin/unzip" // NOSONAR — fixed OS path

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
