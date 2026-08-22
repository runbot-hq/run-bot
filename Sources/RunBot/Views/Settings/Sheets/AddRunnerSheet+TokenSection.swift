// AddRunnerSheet+TokenSection.swift
// RunBot

import Foundation
import GitHubClient
import RunBotCore

// MARK: - GitHub releases API models

/// Single asset entry from the GitHub releases API response.
/// Only `name` and `browser_download_url` are decoded — all other fields are ignored.
private struct RunnerAsset: Decodable {
    /// The asset filename, e.g. `actions-runner-osx-arm64-2.x.y.tar.gz`.
    let name: String
    /// Direct download URL for this asset.
    let browserDownloadUrl: String
    /// Maps `browser_download_url` (snake_case) to `browserDownloadUrl` (camelCase).
    enum CodingKeys: String, CodingKey {
        /// The asset filename key.
        case name
        /// The download URL key.
        case browserDownloadUrl = "browser_download_url"
    }
}

/// Top-level GitHub release object used by `fetchRunnerDownloadURL`.
/// Only the `assets` array is decoded.
private struct RunnerRelease: Decodable {
    /// The list of downloadable assets attached to this release.
    let assets: [RunnerAsset]
}

// MARK: - Runner download URL

/// Queries the GitHub API for the latest macOS runner release and returns the `.tar.gz` download URL
/// matching the current CPU architecture (`arm64` or `x64`).
///
/// Uses `URLSession.data(for:)` async/await — no blocking `Data(contentsOf:)`.
/// Architecture detection uses `ProcessRunner.runAsync` — avoids `waitUntilExit()` on the
/// cooperative thread pool.
func fetchRunnerDownloadURL() async -> String? {
    let archResult = await ProcessRunner.runAsync(
        executableURL: URL(fileURLWithPath: GitHubURIs.unamePath),
        arguments: ["-m"],
        timeout: 5
    )
    let arch = archResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let assetArch = (arch == "arm64") ? "arm64" : "x64"
    let assetName = "actions-runner-osx-\(assetArch)"
    log("fetchRunnerDownloadURL › arch=\(arch) assetName=\(assetName)")

    guard let url = URL(string: GitHubURIs.apiRunnerLatest) else {
        log("fetchRunnerDownloadURL › invalid URL")
        return nil
    }
    let data: Data
    do {
        let (responseData, _) = try await URLSession.shared.data(from: url)
        data = responseData
    } catch {
        log("fetchRunnerDownloadURL › network error: \(error.localizedDescription)")
        return nil
    }
    guard let release = try? JSONDecoder().decode(RunnerRelease.self, from: data) else {
        log("fetchRunnerDownloadURL › decode failed")
        return nil
    }
    let match = release.assets.first { asset in
        asset.name.hasPrefix(assetName) && asset.name.hasSuffix(".tar.gz")
    }
    log("fetchRunnerDownloadURL › match=\(match?.name ?? "nil")")
    return match?.browserDownloadUrl
}

/// Scope-loading and step-reporting helpers for `AddRunnerSheet`.
extension AddRunnerSheet {

    // MARK: - Scopes loader

    /// Fetches the user's repos and organisations on a background thread and updates state on `@MainActor`.
    ///
    /// Uses a plain `Task` (not `Task.detached`). Whether the task starts on `@MainActor` is
    /// **call-site dependent**: `AddRunnerSheet` has no `@MainActor` annotation at the type level,
    /// so a `Task` created here only inherits `@MainActor` if the *caller* is itself `@MainActor`
    /// (e.g. `.onAppear` in a SwiftUI body, which is `@MainActor`-isolated). Do not assume
    /// `@MainActor` inheritance if calling `loadScopes()` from an unannotated context.
    /// State writes are always confined back to the main actor via `await MainActor.run { … }`.
    func loadScopes() {
        isLoadingScopes = true
        Task(priority: .userInitiated) {
            let fetchedRepos = await fetchUserRepos()
            let fetchedOrgs = await fetchUserOrgs()
            await MainActor.run {
                repos = fetchedRepos
                orgs = fetchedOrgs
                if let first = fetchedRepos.first { selectedRepo = first }
                if let first = fetchedOrgs.first { selectedOrg = first }
                isLoadingScopes = false
            }
        }
    }

    /// Updates `registrationStep` on the main actor.
    @MainActor func setStep(_ msg: String) {
        registrationStep = msg
    }
}
