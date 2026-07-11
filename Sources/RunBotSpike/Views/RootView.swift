// Views/RootView.swift
// RunBotSpike - spike/swiftui-nav-sheet

import SwiftUI

struct NavSheetRootView: View {
    @Environment(NavSheetAppState.self) private var appState
    let onPickFolder: () -> Void
    let onPickFolderFromSheet: () -> Void

    var body: some View {
        switch appState.route {
        case .main:
            NavSheetMainView()
                .environment(appState)
                .task {
                    await MainActor.run { appState.taskFireCount += 1 }
                    log("Task", ".task fired count=\(appState.taskFireCount) (should be 1)")
                }
        case .settings:
            NavSheetSettingsView(
                onPickFolder: onPickFolder,
                onPickFolderFromSheet: onPickFolderFromSheet
            )
            .environment(appState)
        }
    }
}
