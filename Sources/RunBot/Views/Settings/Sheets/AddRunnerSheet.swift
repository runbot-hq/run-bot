// AddRunnerSheet.swift
// RunBot
import GitHubClient
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - URI Constants

/// Centralised URI and path constants used by `AddRunnerSheet` and its extensions.
///
/// Intentionally `internal` (not `private`) because the cross-file extension split
/// requires all extension files to access these constants. Do not promote to `public`
/// and do not add constants unrelated to `AddRunnerSheet` here.
///
/// - Note: If `AddRunnerSheet` is ever consolidated back into a single file,
///   restrict this enum to `private`.
enum GitHubURIs {
    /// The base GitHub web URL.
    static let base = "https://github.com/" // NOSONAR — centralised constant, not an inline hardcoded URI
    /// The GitHub API endpoint for the latest Actions runner release.
    static let apiRunnerLatest = "https://api.github.com/repos/actions/runner/releases/latest" // NOSONAR — centralised constant, not an inline hardcoded URI
    /// Relative path to the user's LaunchAgents directory.
    static let launchAgentsDir = "Library/LaunchAgents"
    /// Default runner install directory relative to the user's home folder.
    static let actionsRunnerDefaultDir = "actions-runner/my-runner"
    /// System path to the curl binary used when downloading the runner package.
    static let curlPath = "/usr/bin/curl" // NOSONAR — fixed OS path
    /// System path to the tar binary used when unpacking the runner package.
    static let tarPath = "/usr/bin/tar"  // NOSONAR — fixed OS path
    /// System path to the uname binary used to detect CPU architecture.
    static let unamePath = "/usr/bin/uname" // NOSONAR — fixed OS path
}

/// Sheet view for onboarding a self-hosted runner.
///
/// Supports two modes selectable via a segmented control at the top:
///
/// - **Add new**: downloads, configures and registers a brand-new runner with GitHub.
/// - **Add pre-existing**: imports a runner folder that was already configured outside
///   of RunBot (e.g. via terminal). Only writes the LaunchAgent plist so
///   the runner can be managed — no token or download needed.
///
/// After successful registration/import the app writes a minimal LaunchAgent plist to
/// `~/Library/LaunchAgents/actions.runner.<owner>.<repo>.<name>.plist` directly
/// via FileManager, and registers the runner in `LocalRunnerStore`.
///
/// Requires a GitHub token for "Add new" (OAuth sign-in, GH_TOKEN, or GITHUB_TOKEN).
///
/// ## Visibility note
/// All `@State` properties and extension-facing helpers are `internal` (no modifier)
/// rather than `private` because Swift does not allow `private` members of a primary
/// type to be accessed from extensions defined in separate files. This is an accepted
/// trade-off of the cross-file split; these members remain logically private to the
/// `AddRunnerSheet` family of files.
struct AddRunnerSheet: View {
    /// Controls whether the sheet is shown.
    @Binding var isPresented: Bool
    /// Called when registration or import completes successfully.
    let onComplete: () -> Void
    /// Injected local runner store — avoids direct `.shared` references inside the sheet.
    var localRunnerStore: LocalRunnerStore = .shared
    /// Core runner state — read for synchronous duplicate checks against localRunners.
    /// No default is provided: the value is injected via `AppDelegate.wrapEnv`.
    @Environment(RunnerState.self) var runnerState: RunnerState
    /// Gate that tracks whether any overlay (sheet or file picker) is active.
    /// Used by `pickExistingFolder()` to arm the dismiss gate before opening the picker.
    /// Injected via `AppDelegate.wrapEnv`.
    @Environment(MBKOverlayGate.self) var overlayGate: MBKOverlayGate

    // MARK: - Add Mode

    /// Controls which form body is shown in the sheet.
    enum AddMode: String, CaseIterable, Identifiable {
        /// Onboards a fresh runner via download + registration token.
        case addNew = "Add new"
        /// Imports a runner folder that was configured outside of RunBot.
        case addExisting = "Add pre-existing"
        /// Stable identity backed by `rawValue`.
        var id: String { rawValue }
    }

    /// Whether the user is adding a new runner or importing a pre-existing one.
    @State var addMode: AddMode = .addNew

    // MARK: - Internal state (extension-accessible)
    // These properties have no explicit access modifier (i.e. they are `internal`)
    // rather than `private` so that extensions defined in sibling files
    // (+FormFields, +Validation, +TokenSection) can read and mutate them.
    // They are logically private to the AddRunnerSheet file family and must
    // not be accessed from outside it.

    // MARK: Scope state (Add new only)
    // ScopeType is defined in ScopeType.swift (F-45 / #1644).

    /// Whether the runner is repo-scoped or org-scoped.
    @State var scopeType: ScopeType = .repo
    /// Selected repository slug (used when `scopeType == .repo`).
    @State var selectedRepo = ""
    /// Selected organisation name (used when `scopeType == .org`).
    @State var selectedOrg = ""
    /// Repository slugs fetched from GitHub for the picker.
    @State var repos: [String] = []
    /// Organisation names fetched from GitHub for the picker.
    @State var orgs: [String] = []
    /// `true` while scope options are being fetched from GitHub.
    @State var isLoadingScopes = false
    /// `true` while the repository-selector sheet is presented.
    @State var showRepoSelector = false
    /// `true` while the organisation-selector sheet is presented.
    @State var showOrgSelector = false

    // MARK: Runner config state (Add new only)

    /// Display name the runner will register with.
    @State var runnerName = ""
    /// Comma-separated label string pre-populated with defaults.
    @State var labelsText = "self-hosted,macOS"
    /// Default: ~/actions-runner/my-runner — user should rename the last
    /// component to match their runner name. Each runner needs its own folder.
    @State var installDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path

    // MARK: Registration state (Add new only)

    /// `true` while the registration command is running.
    @State var isRegistering = false
    /// Human-readable description of the current registration step.
    @State var registrationStep = ""
    /// Non-nil when registration fails; shown as an inline error.
    @State var errorMessage: String?

    // MARK: Pre-existing state (Add pre-existing only)

    /// The folder path the user selected via the file picker.
    @State var existingDir = ""
    /// Runner name parsed from the `.runner` JSON inside `existingDir`.
    @State var detectedName = ""
    /// GitHub URL parsed from the `.runner` JSON inside `existingDir`.
    @State var detectedGitHubURL = ""
    /// Shown when the selected folder has no valid `.runner` file or it can't be parsed.
    @State var existingError: String?
    /// Editable fallback shown when `.runner` JSON has no `gitHubUrl` (rare, org-scoped runners).
    @State var githubURLOverride = ""
    /// Whether a runner with this name is already in LocalRunnerStore's index.
    @State var isDuplicate = false

    // MARK: - Body

    /// Root layout: mode picker, form body, and action bar.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner").font(.headline)

            // MARK: Mode toggle
            Picker("Mode", selection: $addMode) {
                ForEach(AddMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: addMode) { _, _ in
                resetAddNewState()
                resetExistingState()
            }

            Divider()

            // MARK: Form body branch
            if addMode == .addNew {
                addNewFormBody
            } else {
                addExistingFormBody
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if addMode == .addNew { loadScopes() }
        }
    }

    // MARK: - State reset helpers

    /// Resets all "Add new" form fields to their initial default values.
    func resetAddNewState() {
        runnerName = ""
        labelsText = "self-hosted,macOS"
        installDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path
        isRegistering = false
        registrationStep = ""
        errorMessage = nil
        scopeType = .repo
        selectedRepo = repos.first ?? ""
        selectedOrg = orgs.first ?? ""
        if addMode == .addNew && repos.isEmpty && orgs.isEmpty {
            loadScopes()
        }
    }

    /// Clears all "Add pre-existing" detection state so a fresh folder can be picked.
    func resetExistingState() {
        existingDir = ""
        detectedName = ""
        detectedGitHubURL = ""
        existingError = nil
        githubURLOverride = ""
        isDuplicate = false
    }

    // MARK: - Plist writer (shared by both modes)

    /// Writes a minimal LaunchAgent plist to `~/Library/LaunchAgents/` for the given runner.
    ///
    /// The plist label is derived as `actions.runner.<owner>.<repo>.<runnerName>` and written
    /// atomically. Used by both the "Add new" and "Add pre-existing" flows.
    ///
    /// - Note: `ProgramArguments` is intentionally omitted. The runner is started by
    ///   `launchctl` invoking `./run.sh` from the `WorkingDirectory`; RunBot only
    ///   needs `Label` + `WorkingDirectory` to identify and manage the agent. A full
    ///   `ProgramArguments` array would be added if RunBot ever needs to bootstrap
    ///   the runner itself rather than relying on the existing `run.sh` mechanism.
    nonisolated func writeLaunchAgentPlist(scope: String, runnerName: String, workingDirectory: String) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.launchAgentsDir)
        let scopeParts = scope.components(separatedBy: "/")
        let owner = scopeParts[0]
        let repo = scopeParts.count > 1 ? scopeParts[1] : scopeParts[0]
        let label = "actions.runner.\(owner).\(repo).\(runnerName)"
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")

        do {
            try FileManager.default.createDirectory(
                at: launchAgentsDir, withIntermediateDirectories: true)
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "WorkingDirectory": workingDirectory],
                format: .xml,
                options: 0
            )
            try plistData.write(to: plistURL, options: .atomic)
            log("AddRunnerSheet › wrote LaunchAgent plist: \(plistURL.path)")
        } catch {
            log("AddRunnerSheet › failed to write LaunchAgent plist: \(error)")
        }
    }

    // MARK: - Process helpers (Add new)

    /// Invokes `config.sh` with the GitHub URL, registration token, runner name and labels.
    ///
    /// `nonisolated`: called via `await` from `@MainActor register()`, which hops off the
    /// main actor for the duration of the subprocess, then returns. This is the load-bearing
    /// design that keeps the main thread free during shell execution.
    /// Do not annotate `@MainActor` — that would prevent the hop and stall the UI.
    ///
    /// Delegates to `ProcessRunner.runAsync` — no blocking `waitUntilExit()` on the pool.
    nonisolated func runRegistrationCommand(
        dir: String, ghURL: String, token: String, name: String, labels: String
    ) async -> Int32 {
        var args = ["--url", ghURL, "--token", token, "--name", name, "--unattended"]
        if !labels.isEmpty { args += ["--labels", labels] }
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: dir).appendingPathComponent("config.sh"),
            arguments: args,
            workingDirectory: URL(fileURLWithPath: dir),
            mergeStderr: true,
            timeout: 120
        )
        log("runRegistrationCommand › exit=\(result.exitCode): \(result.output.prefix(500))")
        return result.exitCode
    }

    /// Launches `executable` with `args` asynchronously and returns the termination status.
    ///
    /// `nonisolated`: called via `await` from `@MainActor register()`, which hops off the
    /// main actor for the duration of the subprocess, then returns. This is the load-bearing
    /// design that keeps the main thread free during shell execution.
    /// Do not annotate `@MainActor` — that would prevent the hop and stall the UI.
    /// Stderr is discarded (default `mergeStderr: false`).
    nonisolated func runSimpleProcess(_ executable: String, args: [String]) async -> Int32 {
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: executable),
            arguments: args,
            timeout: 120
        )
        log("runSimpleProcess › \(executable) exit \(result.exitCode)")
        return result.exitCode
    }

    // MARK: - Register (Add new)

    /// Downloads, unpacks, configures a new runner, registers with `LocalRunnerStore`, and dismisses.
    ///
    /// ## Actor isolation
    /// `register()` is `@MainActor` because every state mutation it performs
    /// (`isRegistering`, `registrationStep`, `errorMessage`, `isPresented`, `onComplete`)
    /// targets `@State` or `@Binding` properties that are `@MainActor`-isolated.
    /// Under Swift 6.2 strict concurrency, writing those properties from a
    /// non-isolated async context is a concurrency error.
    ///
    /// Being on `@MainActor` does **not** block the main thread during `await` calls:
    /// each `await` on a `nonisolated` helper (`runSimpleProcess`, `runRegistrationCommand`)
    /// hops off the main actor while the subprocess runs, then resumes on the main actor
    /// when complete. `setStep(_:)` is also `@MainActor`, so no hop is required.
    @MainActor
    func register() async {
        guard canRegister else { return }
        errorMessage = nil
        registrationStep = ""
        isRegistering = true
        let scope = effectiveScope
        let name = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        let currentScopeType = scopeType

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
            isRegistering = false
            errorMessage = "Install directory must be inside your home folder (~/…)."
            return
        }

        let runnerFile = URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        if FileManager.default.fileExists(atPath: runnerFile) {
            isRegistering = false
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            isRegistering = false
            errorMessage = "Failed to create directory: \(error.localizedDescription)"
            return
        }

        let configPath = URL(fileURLWithPath: dir).appendingPathComponent("config.sh").path

        if !FileManager.default.fileExists(atPath: configPath) {
            setStep("Downloading runner package…")
            guard let downloadURL = await fetchRunnerDownloadURL() else {
                isRegistering = false
                errorMessage = "Could not determine runner download URL. Check your internet connection."
                return
            }
            let tarPath = URL(fileURLWithPath: dir)
                .appendingPathComponent("actions-runner.tar.gz").path
            let curlResult = await runSimpleProcess(
                GitHubURIs.curlPath,
                args: ["-sL", downloadURL, "-o", tarPath]
            )
            guard curlResult == 0 else {
                isRegistering = false
                errorMessage = "Download failed."
                return
            }
            setStep("Unpacking runner package…")
            let tarResult = await runSimpleProcess(GitHubURIs.tarPath, args: ["xzf", tarPath, "-C", dir])
            try? FileManager.default.removeItem(atPath: tarPath)
            guard tarResult == 0 else {
                isRegistering = false
                errorMessage = "Unpack failed."
                return
            }
        }

        setStep("Fetching registration token…")
        guard let token = await fetchRegistrationToken(scope: scope) else {
            isRegistering = false
            if currentScopeType == .org {
                errorMessage = "Not authorised to register org-level runners. Ensure your token has the ‘manage_runners:org’ scope, or sign in via the GitHub button in Settings."
            } else {
                errorMessage = "Could not get a registration token. Ensure a valid token is available via OAuth sign-in, or the GH_TOKEN / GITHUB_TOKEN environment variable."
            }
            return
        }

        setStep("Configuring runner…")
        let ghURL = "\(GitHubURIs.base)\(scope)"
        let configExit = await runRegistrationCommand(
            dir: dir, ghURL: ghURL, token: token, name: name, labels: labels
        )
        guard configExit == 0 else {
            isRegistering = false
            errorMessage = "config.sh failed (exit \(configExit)). Check the token is valid and the runner name is unique."
            return
        }

        setStep("Registering service…")
        writeLaunchAgentPlist(scope: scope, runnerName: name, workingDirectory: dir)
        // Await directly — register() is already async, no Task wrapper needed.
        // This guarantees add() completes before isPresented = false fires and
        // onComplete() enqueues its refresh(), so the new runner row is always
        // present in the actor's index before the scan runs.
        await localRunnerStore.add(runnerName: name, installPath: dir)
        isRegistering = false
        registrationStep = ""
        isPresented = false
        onComplete()
    }
}
