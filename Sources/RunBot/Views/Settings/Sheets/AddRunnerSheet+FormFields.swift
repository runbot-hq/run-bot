// AddRunnerSheet+FormFields.swift
// RunBot

import GitHubClient
import MenuBarKit
import RunBotCore
import SwiftUI

/// Form field subviews and pre-existing folder actions for `AddRunnerSheet`.
extension AddRunnerSheet {

    // MARK: - Add New Form Body

    /// Form fields shown when the user selects the "Add new" mode:
    /// scope picker, repo/org selector, runner name, labels, and install path.
    @ViewBuilder
    var addNewFormBody: some View {
        Picker("Scope", selection: $scopeType) {
            ForEach(ScopeType.allCases) { scopeOption in Text(scopeOption.rawValue).tag(scopeOption) }
        }
        .pickerStyle(.segmented)

        if isLoadingScopes {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading…").font(.caption).foregroundColor(Color.rbTextSecondary)
            }
        } else if scopeType == .repo {
            selectorButton(
                label: "Repository",
                selection: selectedRepo,
                action: { showRepoSelector = true }
            )
            .sheet(isPresented: $showRepoSelector) {
                RepoSelectorSheet(
                    items: repos,
                    label: "Repository",
                    onDismiss: { showRepoSelector = false },
                    onSelect: { item in
                        selectedRepo = item
                        // No dismiss here -- RepoSelectorSheet.itemRow calls onDismiss
                        // after onSelect. Adding showRepoSelector = false here would
                        // cause a double-dismiss and a SwiftUI sheet lifecycle warning.
                    }
                )
            }
        } else {
            selectorButton(
                label: "Organisation",
                selection: selectedOrg,
                action: { showOrgSelector = true }
            )
            .sheet(isPresented: $showOrgSelector) {
                RepoSelectorSheet(
                    items: orgs,
                    label: "Organisation",
                    onDismiss: { showOrgSelector = false },
                    onSelect: { item in
                        selectedOrg = item
                        // No dismiss here -- RepoSelectorSheet.itemRow calls onDismiss
                        // after onSelect. Adding showOrgSelector = false here would
                        // cause a double-dismiss and a SwiftUI sheet lifecycle warning.
                    }
                )
            }
        }

        labeledField(
            "Labels (comma-separated)",
            placeholder: "e.g. self-hosted,macOS,arm64",
            text: $labelsText
        )
        labeledField("Runner name", placeholder: "e.g. my-mac-runner", text: $runnerName)

        VStack(alignment: .leading, spacing: 4) {
            Text("Runner parent directory").font(.caption).foregroundStyle(Color.rbTextSecondary)
            HStack(spacing: RBSpacing.sm) {
                TextField("", text: $installDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .layoutPriority(1)
                    .accessibilityLabel("Runner parent directory")
                Button("Choose…") {
                    chooseNewRunnerParentDirectory()
                }
                .fixedSize()
                .disabled(isRegistering)
                .accessibilityLabel("Choose runner parent directory")
            }
            Text("RunBot creates a runner folder with the runner name inside this directory.")
                .font(.caption2)
                .foregroundStyle(Color.rbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: Final path preview
        VStack(alignment: .leading, spacing: 4) {
            Text("Final runner path").font(.caption).foregroundStyle(Color.rbTextSecondary)
            if let finalPath = finalInstallPath {
                Text(finalPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.rbTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("Final runner path")
                    .accessibilityValue(finalPath)
            } else if !trimmedRunnerName.isEmpty && !runnerNameIsValidPathComponent {
                Text("Runner name must be a single folder name and cannot contain \"/\".")
                    .font(.caption2)
                    .foregroundStyle(Color.rbDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Enter a runner name to preview the final path.")
                    .font(.caption2)
                    .foregroundStyle(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if dirAlreadyConfigured {
                Label(
                    "This folder already has a runner configured. Choose a different path.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundColor(.orange)
            }
        }

        if isRegistering && !registrationStep.isEmpty {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(registrationStep).font(.caption).foregroundColor(Color.rbTextSecondary)
            }
        }

        if let err = errorMessage {
            Text(err)
                .font(.caption).foregroundColor(.red)
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
        }

        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(isRegistering)
            Button {
                // Task runs on @MainActor because this Button closure is
                // @MainActor-isolated (SwiftUI View body context).
                Task { await register() }
            } label: {
                if isRegistering {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        Text("Registering…")
                    }
                } else {
                    Text("Add new runner")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRegister || isRegistering)
        }
    }

    // MARK: - Add Pre-Existing Form Body

    /// Form fields shown when the user selects the "Add pre-existing" mode:
    /// folder picker, detected runner name, and GitHub URL display/override.
    @ViewBuilder
    var addExistingFormBody: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Folder picker row
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install folder").font(.caption).foregroundColor(Color.rbTextSecondary)
                HStack(spacing: 8) {
                    Text(existingDir.isEmpty ? "No folder selected" : existingDir)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(
                            existingDir.isEmpty
                                ? Color.rbTextSecondary
                                : Color.rbTextPrimary
                        )
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button {
                        pickExistingFolder()
                    } label: {
                        Text("Choose…")
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            // Detected fields (shown once a valid folder is picked)
            if !detectedName.isEmpty {
                labeledReadOnly("Runner name (detected)", value: detectedName)

                if detectedGitHubURL.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub URL").font(.caption).foregroundColor(Color.rbTextSecondary)
                        TextField("\(GitHubURIs.base)owner/repo", text: $githubURLOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("The .runner file has no GitHub URL. Paste the repo or org URL above.")
                            .font(.caption2)
                            .foregroundColor(Color.rbTextSecondary)
                    }
                } else {
                    labeledReadOnly("GitHub URL (detected)", value: detectedGitHubURL)
                }
            }

            // Error state
            if let err = existingError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            // Duplicate warning
            if isDuplicate {
                Label(
                    "This runner is already tracked by RunBot.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Import Runner") { Task { await importExistingRunner() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
    }

    // MARK: - Sub-views

    /// Selector button that opens the searchable `RepoSelectorSheet`.
    ///
    /// Shows the current selection as the button label, or a "— select —" placeholder
    /// when nothing has been chosen. A hint is shown below when the list is empty.
    @ViewBuilder
    func selectorButton(label: String, selection: String,
                        action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(Color.rbTextSecondary)
            Button(action: action) {
                HStack {
                    Text(selection.isEmpty ? "— select —" : selection)
                        .font(.system(size: 12))
                        .foregroundStyle(
                            selection.isEmpty
                                ? Color.rbTextSecondary
                                : Color.rbTextPrimary
                        )
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            if selection.isEmpty {
                Text("No \(label.lowercased())s found. Sign in with GitHub or set GH_TOKEN / GITHUB_TOKEN.")
                    .font(.caption2).foregroundColor(Color.rbTextSecondary)
            }
        }
    }

    /// Renders a caption label above a `TextField` with rounded-border style.
    @ViewBuilder
    func labeledField(_ title: String, placeholder: String,
                      text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(Color.rbTextSecondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// Read-only monospaced display field used in the pre-existing form.
    @ViewBuilder
    func labeledReadOnly(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(Color.rbTextSecondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    // MARK: - Actions (Add new)

    /// Opens a sheet-safe directory picker for the new runner's parent directory.
    ///
    /// Mirrors `pickExistingFolder()` so that `overlayGate` is armed before the
    /// panel opens — preventing the outside-click monitor from dismissing the sheet.
    /// On confirmation, writes the chosen URL to `installDir` (the parent directory).
    /// Does not call `resetExistingState()` or treat the folder as an existing runner.
    func chooseNewRunnerParentDirectory() {
        log("AddRunnerSheet › chooseNewRunnerParentDirectory — opening via mbkOpenFilePicker")
        mbkOpenFilePicker(
            overlayGate: overlayGate,
            message: "Select the parent directory for the new runner"
        ) { url in
            log("AddRunnerSheet › chooseNewRunnerParentDirectory — picker closed url=\(String(describing: url))")
            guard let url else { return }
            installDir = url.standardizedFileURL.path
        }
    }

    // MARK: - Actions (Add pre-existing)

    /// Opens a directory picker via `mbkOpenFilePicker`.
    ///
    /// `mbkOpenFilePicker` arms `overlayGate.hasActiveOverlay` before opening so the
    /// outside-click monitor is blocked for the full lifetime of the panel.
    func pickExistingFolder() {
        log("AddRunnerSheet › pickExistingFolder — opening via mbkOpenFilePicker")
        mbkOpenFilePicker(
            overlayGate: overlayGate,
            message: "Select the runner install folder (must contain a .runner file)"
        ) { url in
            log("AddRunnerSheet › pickExistingFolder — picker closed url=\(String(describing: url))")
            guard let url else { return }
            handlePickedFolder(url)
        }
    }

    /// Validates the picked folder and populates the detected-runner state.
    func handlePickedFolder(_ url: URL) {
        resetExistingState()
        existingDir = url.path

        let runnerFileURL = url.appendingPathComponent(".runner")
        guard FileManager.default.fileExists(atPath: runnerFileURL.path) else {
            existingError = "No .runner file found in the selected folder. Is this a valid runner install directory?"
            return
        }

        // Delegate to RunnerModelParser so BOM stripping is applied consistently
        // with the store-hydration path (the GitHub Actions runner agent writes
        // BOM-prefixed JSON, which a bare JSONDecoder call would reject).
        let folderName = url.lastPathComponent
        guard let model = runnerModelFromIndex(name: folderName, installPath: url.path) else {
            existingError = "Could not parse .runner file. It may be malformed."
            return
        }

        // Prefer the registered AgentName from the parsed model; fall back to
        // the folder's last path component if absent or empty.
        let nameFromFile = model.runnerName.isEmpty ? nil : model.runnerName
        detectedName = nameFromFile ?? folderName
        detectedGitHubURL = model.gitHubUrl?.absoluteString ?? ""
        isDuplicate = checkDuplicate(runnerName: detectedName)

        log("AddRunnerSheet › pre-existing: name=\(detectedName) url=\(detectedGitHubURL) duplicate=\(isDuplicate)")
    }

    /// Writes the LaunchAgent plist, registers with `LocalRunnerStore`, and dismisses the sheet.
    ///
    /// WHY @MainActor + async WITHOUT a Task WRAPPER AT THE CALL SITE:
    ///   The Button action closure that calls this is already @MainActor-isolated
    ///   (SwiftUI View body context). `importExistingRunner` is `async` so its
    ///   `await localRunnerStore.add(...)` suspension can hop off the main actor
    ///   for the store work and return. The caller wraps it in `Task { await ... }`
    ///   so the button action remains synchronous. Inside this function there is no
    ///   need for an additional Task wrapper — `await` is used directly.
    @MainActor
    func importExistingRunner() async {
        guard canImport else { return }

        let scope = effectiveGitHubURL
            .replacingOccurrences(of: GitHubURIs.base, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !scope.isEmpty else {
            existingError = "Could not derive a scope from the GitHub URL. Please check the URL."
            return
        }

        writeLaunchAgentPlist(
            scope: scope,
            runnerName: detectedName,
            workingDirectory: existingDir
        )
        // Await directly — importExistingRunner() is async; no inner Task wrapper needed.
        await localRunnerStore.add(runnerName: detectedName, installPath: existingDir)
        isPresented = false
        onComplete()
    }
}
