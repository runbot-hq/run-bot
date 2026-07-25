// MainView.swift
// MenuBarKitExample

import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    private let allItems: [(icon: String, label: String)] = [
        ("checkmark.circle.fill",  "Build succeeded"),
        ("xmark.circle.fill",      "Test suite failed on runner macos-15-xl"),
        ("clock.fill",             "Queued"),
        ("arrow.clockwise",        "Re-running deploy-production"),
        ("checkmark.circle.fill",  "Lint passed"),
        ("xmark.circle.fill",      "E2E tests timed out after 60 minutes on staging"),
        ("clock.fill",             "Waiting for approval"),
        ("checkmark.circle.fill",  "Release build complete — v2.4.1"),
        ("arrow.clockwise",        "Retrying flaky snapshot test"),
        ("xmark.circle.fill",      "Deploy failed: health check did not pass"),
        ("checkmark.circle.fill",  "OK"),
        ("clock.fill",             "Pending dependency: upload-artifacts"),
        ("checkmark.circle.fill",  "Code signing passed"),
        ("xmark.circle.fill",      "Notarisation rejected"),
        ("arrow.clockwise",        "Scheduled nightly run"),
        ("checkmark.circle.fill",  "Delta upload done"),
        ("clock.fill",             "In progress"),
        ("xmark.circle.fill",      "Runner disconnected mid-job — investigate logs"),
        ("checkmark.circle.fill",  "Cache warmed"),
        ("checkmark.circle.fill",  "All checks passed — ready to merge"),
    ]

    @State private var visibleCount = 5

    var body: some View {
        #if DEBUG
        let _ = print("[MainView] body evaluated — visibleCount=\(visibleCount)")
        #endif
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workflows").font(.headline)
                Spacer()
                Button("Settings →") {
                    #if DEBUG
                    print("[MainView] Settings tapped")
                    #endif
                    appState.route = .settings
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(allItems.prefix(visibleCount).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .foregroundStyle(iconColor(item.icon))
                                .font(.caption)
                            Text(item.label)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        Divider()
                    }

                    if visibleCount < allItems.count {
                        let nextBatch = min(5, allItems.count - visibleCount)
                        Button("Show \(nextBatch) more…") {
                            #if DEBUG
                            print("[MainView] Show more tapped — visibleCount \(visibleCount) -> \(visibleCount + nextBatch)")
                            #endif
                            visibleCount += nextBatch
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize()
        .onAppear    {
            #if DEBUG
            print("[MainView] onAppear visibleCount=\(visibleCount)")
            #endif
        }
        .onDisappear {
            #if DEBUG
            print("[MainView] onDisappear")
            #endif
        }
    }

    private func iconColor(_ systemName: String) -> Color {
        switch systemName {
        case "checkmark.circle.fill": return .green
        case "xmark.circle.fill":     return .red
        case "clock.fill":            return .orange
        default:                      return .blue
        }
    }
}
