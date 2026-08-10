// ZIPCacheKey.swift
// RunBotCore
import Foundation

// MARK: - ZIPCacheGroupKey

/// Identifies one displayed workflow group and its ZIP-cache directory.
///
/// The folder name is derived from `repo`, `headSha`, and `normalizedEvent` so that
/// separate events on the same SHA (e.g. `commit` vs `workflow_dispatch`) always land
/// in separate directories, and runs from different repositories never collide.
public struct ZIPCacheGroupKey: Hashable, Sendable {
    /// The `owner/repo` string, e.g. `"runbot-hq/run-bot"`.
    public let repo: String
    /// The full commit SHA for this group's head.
    public let headSha: String
    /// The normalised GitHub event string, e.g. `"commit"` or `"workflow_dispatch"`.
    public let normalizedEvent: String

    public init(
        repo: String,
        headSha: String,
        normalizedEvent: String
    ) {
        self.repo = repo
        self.headSha = headSha
        self.normalizedEvent = normalizedEvent
    }

    /// Readable, single-level directory name used on disk.
    ///
    /// Slashes in the repo string are replaced with `@` so the name is a valid
    /// single path component. Example:
    /// `"runbot-hq@run-bot--fb306a5bcaad562d2e7bc183b86e4a70e983c3dd--commit"`
    public var folderName: String {
        let encodedRepo = repo.replacingOccurrences(of: "/", with: "@")
        return "\(encodedRepo)--\(headSha)--\(normalizedEvent)"
    }
}

// MARK: - ZIPCacheEntryKey

/// Identifies one exact workflow-run log archive within a group directory.
///
/// GitHub keeps the same run ID across a rerun while incrementing `run_attempt`,
/// so both values are required for exact log identity.
public struct ZIPCacheEntryKey: Hashable, Sendable {
    /// The group (folder) this archive lives in.
    public let group: ZIPCacheGroupKey
    /// The GitHub workflow run ID.
    public let runID: Int
    /// The attempt number for this run. Starts at 1; incremented on each rerun.
    public let runAttempt: Int

    public init(
        group: ZIPCacheGroupKey,
        runID: Int,
        runAttempt: Int
    ) {
        self.group = group
        self.runID = runID
        self.runAttempt = runAttempt
    }

    /// Filename used on disk: `"{runID}-{runAttempt}.zip"`.
    public var fileName: String { "\(runID)-\(runAttempt).zip" }
}
