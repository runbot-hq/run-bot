// Views/MainView.swift
// RunBotSpike - spike/swiftui-nav-sheet

import SwiftUI

struct NavSheetMainView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Nav + Sheet Spike")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Counter (persists on hide)") {
                HStack {
                    Text("\(appState.counter)").monospacedDigit().frame(minWidth: 24)
                    Spacer()
                    Button("+1") {
                        appState.counter += 1
                        log("MainView", "counter=\(appState.counter)")
                    }
                }
            }

            GroupBox("TextField (persists on hide)") {
                TextField("Type here...", text: $appState.text)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox(".task fire count") {
                Text("\(appState.taskFireCount)x").monospacedDigit()
                if appState.taskFireCount > 1 {
                    Text("FAIL: fired more than once - view recreated")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("PASS: fired once")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            Button("Go to Settings") {
                log("Nav", "route: main -> settings")
                appState.route = .settings
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 320)
    }
}
