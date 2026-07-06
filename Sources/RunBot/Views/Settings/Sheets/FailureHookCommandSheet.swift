// FailureHookCommandSheet.swift
// RunBot
import AppKit
import RunBotCore
import SwiftUI

// MARK: - FailureHookCommandSheet
// #544: Sheet for editing the per-scope failure hook command.
// #546: Added Test button + $LOCAL_PATH token.
//
// Presented from ScopeEditSheet when user taps the Command row.
// Uses TextEditor (tall, monospaced) with variable pill buttons that insert at cursor.

/// Sheet for editing the shell command run by `FailureHookRunner` when a workflow fails.
/// Provides a monospaced `TextEditor` and variable-insertion pill buttons.
struct FailureHookCommandSheet: View {
    /// The scope (org/repo slug) whose failure-hook command is being edited.
    let scope: String
    /// The unsaved local-repo path draft from `ScopeEditSheet`, used by `testCommand()`
    /// so the test reflects the path the user will actually save, not the last persisted value.
    let localRepoPath: String
    /// Called when the sheet should be dismissed, either after saving or on cancel.
    let onDismiss: () -> Void

    /// The parent draft value. Only written on Save — never mutated directly by the editor.
    @Binding var commandText: String
    /// Local working copy of the command text. Bound to the TextEditor so every
    /// keystroke stays inside this sheet. Committed to `commandText` only when
    /// the user taps Save; Cancel discards it, leaving the parent draft unchanged.
    @State private var draft: String

    /// Initialises the sheet for `scope`, seeding the local editor from `commandText`.
    init(scope: String, localRepoPath: String, commandText: Binding<String>, onDismiss: @escaping () -> Void) {
        self.scope = scope
        self.localRepoPath = localRepoPath
        self._commandText = commandText
        self.onDismiss = onDismiss
        // Show the default command as a starting point when nothing has been saved yet,
        // but never write it back unless the user explicitly taps Save.
        let initial = commandText.wrappedValue
        _draft = State(initialValue: initial.isEmpty ? FailureHookRunner.defaultCommand : initial)
    }

    /// Shell-variable tokens the user can insert into the command, e.g. `$SCOPE`, `$FAILURE_LOG`.
    /// Rendered as pill buttons in `pillSection`; tapping a pill appends the token to `draft`.
    private let variables: [String] = [
        "$SCOPE", "$LOCAL_PATH", "$BRANCH", "$RUN_ID", "$COMMIT_SHA",
        "$WORKFLOW_NAME", "$FAILURE_LOG",
        "$RUN_LINK", "$COMMIT_LINK", "$BRANCH_LINK", "$REPO_LINK"
    ]

    /// Lays out the header, command editor, variable pills, and footer action buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            editorSection
            pillSection
            footerSection
        }
        .frame(width: 440)
        .glassCard(cornerRadius: 10)
    }
}

// MARK: - Subviews

/// View subcomponents for `FailureHookCommandSheet`: header, monospaced editor, variable-pill bar, and footer actions.
extension FailureHookCommandSheet {
    /// Header block: sheet title and usage description.
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Failure Hook Command")
                .font(.system(size: 13, weight: .semibold))
            Text("Called in your default shell when a run in this scope fails. Use '$FAILURE_LOG' to inline the log text — all tokens are resolved before the shell runs the command.")
                .font(.caption)
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// Monospaced `TextEditor` bound to the local `draft` copy.
    var editorSection: some View {
        TextEditor(text: $draft)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color.rbSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
            )
            .frame(minHeight: 160, idealHeight: 180)
            .padding(.horizontal, 16)
    }

    /// Flow-wrapped pill buttons that append a variable token to `draft`.
    var pillSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Insert variable:")
                .font(.caption2)
                .foregroundColor(Color.rbTextTertiary)
            FlowLayout(spacing: 5) {
                ForEach(variables, id: \.self) { variable in
                    Button(action: { insertVariable(variable) }) {
                        Text(variable)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.rbTextSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .glassCard(cornerRadius: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// Cancel / Test / Save action bar.
    var footerSection: some View {
        HStack {
            Spacer()
            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .glassCard(cornerRadius: 6)
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: { testCommand() }) {
                    Label("Test", systemImage: "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.rbAccent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .glassCard(cornerRadius: 6)
                .help("Run this command in Terminal now")
            }
            Button("Save") { save() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.rbAccent))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

// MARK: - Actions

/// Action handlers for `FailureHookCommandSheet`: persisting the command, running a test in Terminal, and inserting variable tokens.
extension FailureHookCommandSheet {
    /// Commits `draft` to the parent binding and dismisses. Persistence is owned by `ScopeEditSheet.confirmSave()`.
    private func save() {
        log("FailureHookCommandSheet › save — scope=\(scope) draft='\(draft.prefix(200))'")
        commandText = draft
        onDismiss()
    }

    /// Resolves `$LOCAL_PATH` and `$SCOPE` then opens the command in Terminal.
    /// NOTE: Only `$LOCAL_PATH` and `$SCOPE` are pre-resolved here; runtime-only tokens
    /// (`$FAILURE_LOG`, `$BRANCH`, `$RUN_ID`, etc.) are left as-is and will appear
    /// literally in the terminal window during a test run.
    private func testCommand() {
        // Use the unsaved draft path passed from ScopeEditSheet, not the persisted store value,
        // so the test reflects what the hook will actually use after Save.
        let localPath = localRepoPath
        let resolved = draft
            .replacingOccurrences(of: "$LOCAL_PATH", with: localPath)
            .replacingOccurrences(of: "$SCOPE", with: scope)
        log("FailureHookCommandSheet › testCommand — scope=\(scope) localPath='\(localPath)' resolved='\(resolved.prefix(200))'")
        TerminalLauncher.open(command: resolved)
    }

    /// Appends `variable` to `draft`, separated by a space.
    /// NOTE: `TextEditor` exposes no public cursor-position API on macOS, so the
    /// token is always appended rather than inserted at the caret.
    private func insertVariable(_ variable: String) {
        if draft.isEmpty {
            draft = variable
        } else {
            draft += " " + variable
        }
    }
}

