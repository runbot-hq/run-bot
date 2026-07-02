// AppUpdater+Download.swift
// AppUpdater
import CryptoKit
import Foundation

// MARK: - Download

/// Download, checksum verification, and local cache management for AppUpdater.
extension AppUpdater {

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies
    /// integrity, then caches the verified zip at `fixedZipURL` and advances
    /// host state.
    ///
    /// State transitions:
    ///   `.available` → `.downloading` (on entry)
    ///   `.downloading` → `.ready`     (checksum-verified success)
    ///   `.downloading` → `.failed`    (any error)
    ///
    /// ## Fire-and-forget rationale
    ///
    /// Invoked from a fire-and-forget `Task(name: "AppUpdater.download")` in
    /// `handle()`. AppUpdater is process-lifetime; `@MainActor` serialises all
    /// state mutations. No stored task handle or cancellation is needed.
    ///
    /// ## .downloading phase reachability
    ///
    /// A reviewer tracing `UpdatePhase.downloading` through the codebase may
    /// find it hard to locate — it is applied on the very first line of this
    /// function, not at the call site in `handle()`. The call chain is:
    ///   `handle()` → `Task(name: "AppUpdater.download")` → `downloadUpdate()`
    ///   → `state.apply(.downloading(...))` (line 1 of the function body).
    ///
    /// `.downloading` is NOT applied in `handle()` before the Task fires
    /// because the Task is fire-and-forget — there is no guarantee of
    /// ordering between the `.available` apply in `handle()` and the Task
    /// body. Applying it here (inside the Task, on @MainActor) guarantees
    /// the transition is serialised correctly.
    ///
    /// ## checksumURL is non-optional by design
    ///
    /// `handle()` guards `release.checksumURL != nil` before spawning this Task
    /// — a nil checksumURL never reaches this function. The parameter is `URL`
    /// (non-optional) to make that invariant explicit at the type level and
    /// remove any unreachable nil-handling code (Principle 1: illegal states
    /// unrepresentable by construction).
    func downloadUpdate( // skipcq: SW-R1002 — reviewed; complexity acceptable for this download+verify flow
        from url: URL,
        checksumURL: URL,
        version: String,
        state: any UpdateStateProviding
    ) async {
        state.apply(.downloading(version: version))

        var tempURL: URL?
        do {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)
            defer { session.finishTasksAndInvalidate() }

            async let zipDownload = session.download(from: url)
            async let checksumDownload = session.data(from: checksumURL)
            let (downloadedURL, zipResponse) = try await zipDownload
            tempURL = downloadedURL
            let (checksumData, checksumResponse) = try await checksumDownload

            // ── Validate zip HTTP status ─────────────────────────────────────
            guard let zipHTTP = zipResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard zipHTTP.statusCode == 200 else {
                appUpdaterLogger.error("zip download returned HTTP \(zipHTTP.statusCode, privacy: .public)")
                throw URLError(.badServerResponse)
            }

            // ── Validate checksum sidecar HTTP status ────────────────────────
            guard let checksumHTTP = checksumResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard checksumHTTP.statusCode == 200 else {
                appUpdaterLogger.error("checksum sidecar returned HTTP \(checksumHTTP.statusCode, privacy: .public) — release may have been published without a .sha256 file")
                throw URLError(.badServerResponse)
            }

            // ── Parse and validate the expected hex string ───────────────────
            let rawChecksum = String(bytes: checksumData, encoding: .utf8) ?? ""
            let expectedHex = rawChecksum
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? ""

            guard !expectedHex.isEmpty else {
                appUpdaterLogger.error("checksum sidecar returned HTTP 200 but body was empty or whitespace-only")
                throw URLError(.cannotDecodeContentData)
            }

            try await verifyChecksum(zipURL: downloadedURL, expectedHex: expectedHex)

            // ── Move verified zip to fixed destination ───────────────────────
            let destination = try cachedZipDestination()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloadedURL, to: destination)

            state.apply(.ready(version: version, zipURL: destination))
        } catch {
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }
            state.apply(.failed(version: version))
        }
    }
}
