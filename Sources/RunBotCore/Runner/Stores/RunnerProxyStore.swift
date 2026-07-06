// RunnerProxyStore.swift
// RunBotCore
import Foundation

// MARK: - RunnerProxyStore

/// Actor that owns all disk read/write for runner proxy configuration files.
///
/// Conforms to `RunnerProxyStoreProtocol` so it can be replaced with a test double
/// when injected into `SaveRunnerEditsUseCase`.
///
/// Replaces the `loadProxy` private helper in `RunnerEditDraft` and the
/// `writeProxyFiles` / `removeIfPresent` free functions in `CommitRunnerEdit`.
///
/// Disk I/O is performed in `@concurrent` free functions so the actor's
/// cooperative thread is never blocked by synchronous file I/O (P18).
///
/// File format (unchanged from previous implementation):
/// - `.proxy`            — raw proxy URL followed by `"\n"`.
/// - `.proxycredentials` — `user + "\n" + password + "\n"`.
///
/// Moved from `RunBot` to `RunBotCore` in #1612.
/// `RunnerProxyStoreProtocol`, `RunnerProxyConfig`, and `RunnerProxyStoreError`
/// were already in Core — this completes the proxy subsystem.
///
/// - Note: Part of Phase 4 of the Swift 6.2 data model modernisation (#1287, #1299).
public actor RunnerProxyStore: RunnerProxyStoreProtocol {

    // MARK: Shared instance

    /// The shared singleton instance.
    public static let shared = RunnerProxyStore()

    // MARK: Init

    /// Use `RunnerProxyStore.shared` — direct instantiation is not permitted.
    private init() { /* singleton — use RunnerProxyStore.shared */ }

    // MARK: - load(at:)

    /// Reads `.proxy` and `.proxycredentials` at `installPath`.
    ///
    /// Disk I/O runs in a `@concurrent` free function so the actor's cooperative
    /// thread is never blocked. Non-throwing: missing files return a zeroed config.
    public func load(at installPath: String) async -> RunnerProxyConfig {
        let base = URL(fileURLWithPath: installPath)
        return await loadProxyFiles(
            proxyURL: base.appendingPathComponent(".proxy"),
            credURL: base.appendingPathComponent(".proxycredentials")
        )
    }

    // MARK: - save(_:at:)

    /// Writes (or removes) `.proxy` and `.proxycredentials` at `installPath`.
    ///
    /// Disk I/O runs in a `@concurrent` free function so the actor's cooperative
    /// thread is never blocked. Trimming and file operations happen entirely
    /// inside the `@concurrent` helper.
    ///
    /// Each file is handled independently so a failure on one does not mask
    /// a failure on the other. If either write fails,
    /// `RunnerProxyStoreError.writeFailed` is thrown with all accumulated messages.
    public func save(_ config: RunnerProxyConfig, at installPath: String) async throws(RunnerProxyStoreError) {
        let base = URL(fileURLWithPath: installPath)
        do {
            try await saveProxyFiles(
                config,
                proxyURL: base.appendingPathComponent(".proxy"),
                credURL: base.appendingPathComponent(".proxycredentials")
            )
        } catch let proxyError as RunnerProxyStoreError {
            throw proxyError
        } catch {
            // Defensive bridge: saveProxyFiles only throws RunnerProxyStoreError,
            // but typed-throw bridging through `any Error` requires this catch.
            throw RunnerProxyStoreError.writeFailed([error.localizedDescription])
        }
    }
}

// MARK: - @concurrent disk helpers

/// Reads `.proxy` and `.proxycredentials` from disk.
///
/// Marked `@concurrent` so Swift's cooperative thread pool schedules this
/// off the actor's serial executor. The I/O is synchronous inside the body;
/// `@concurrent` provides the off-actor scheduling (P18).
///
/// Non-throwing: missing files are the normal case and return empty strings.
/// Non-ENOENT read errors are logged and also produce empty fields — callers
/// cannot distinguish a read failure from a missing file, which is intentional
/// for `load`: an unreadable proxy config is treated as "no proxy".
@concurrent
private func loadProxyFiles(proxyURL: URL, credURL: URL) async -> RunnerProxyConfig {
    let url: String
    do {
        url = try String(contentsOf: proxyURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
    } catch let err as NSError where err.code == NSFileNoSuchFileError {
        url = ""
    } catch {
        log("RunnerProxyStore › .proxy read error (using empty): \(error)", category: .runner)
        url = ""
    }

    var user = ""
    var credential = ""
    do {
        let credContent = try String(contentsOf: credURL, encoding: .utf8)
        (user, credential) = parseCredentialLines(credContent)
    } catch let err as NSError where err.code == NSFileNoSuchFileError {
        // Missing credentials file is expected — most runners have no proxy.
    } catch {
        log("RunnerProxyStore › .proxycredentials read error (using empty): \(error)", category: .runner)
    }

    return RunnerProxyConfig(url: url, user: user, password: credential)
}

/// Writes (or removes) `.proxy` and `.proxycredentials` to disk.
///
/// Marked `@concurrent` so Swift's cooperative thread pool schedules this
/// off the actor's serial executor (P18). Trimming happens here so the
/// actor thread has no I/O work at all.
///
/// Both files are always attempted independently. All failures are
/// accumulated into a single `RunnerProxyStoreError.writeFailed` throw
/// so callers see the full picture rather than a truncated first-error.
@concurrent
private func saveProxyFiles(
    _ config: RunnerProxyConfig,
    proxyURL: URL,
    credURL: URL
) async throws {
    let url = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
    let user = config.user.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = config.password.trimmingCharacters(in: .whitespacesAndNewlines)

    var messages: [String] = []

    do {
        try writeProxyURL(url, to: proxyURL)
    } catch {
        let msg = ".proxy write error: \(error)"
        log("RunnerProxyStore › \(msg)", category: .runner)
        messages.append(msg)
    }

    do {
        try writeProxyCredentials(user: user, secret: secret, to: credURL)
    } catch {
        let msg = ".proxycredentials write error: \(error)"
        log("RunnerProxyStore › \(msg)", category: .runner)
        messages.append(msg)
    }

    if !messages.isEmpty {
        throw RunnerProxyStoreError.writeFailed(messages)
    }
}

// MARK: - Private file helpers

/// Parses the raw credential file content into `user` and `password` components.
///
/// Expects the first line to be the username and the second line (if present)
/// to be the password. Missing lines yield empty strings.
///
/// Trims `.whitespacesAndNewlines` (not just `.newlines`) so that files written
/// with `\r\n` line endings (e.g. by Windows-based credential tools) do not leave
/// a trailing `\r` on each component — which would silently break proxy authentication.
private func parseCredentialLines(_ content: String) -> (user: String, password: String) {
    let lines = content.components(separatedBy: "\n")
    let user = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    let credential = lines.indices.contains(1) ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return (user, credential)
}

/// Writes the proxy URL to `destination` as `url + "\n"`, or removes the file if `url` is empty.
private func writeProxyURL(_ url: String, to destination: URL) throws {
    if url.isEmpty {
        try removeIfPresent(at: destination)
    } else {
        try (url + "\n").write(to: destination, atomically: true, encoding: .utf8)
    }
}

/// Writes the proxy credentials to `destination` as `user + "\n" + secret + "\n"`,
/// or removes the file when both values are empty.
private func writeProxyCredentials(user: String, secret: String, to destination: URL) throws {
    if user.isEmpty && secret.isEmpty {
        try removeIfPresent(at: destination)
    } else {
        try (user + "\n" + secret + "\n").write(to: destination, atomically: true, encoding: .utf8)
    }
}

/// Removes the file at `url` if it exists; silently ignores `NSFileNoSuchFileError`.
/// Any other error is re-thrown so callers can distinguish a missing file
/// (harmless) from a genuine I/O failure (permissions, locked volume, etc.).
private func removeIfPresent(at url: URL) throws {
    do {
        try FileManager.default.removeItem(at: url)
    } catch let error as NSError where error.code == NSFileNoSuchFileError {
        // File didn't exist — expected, not an error.
    }
}
