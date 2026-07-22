// APICallCounterRow.swift
// RunBot
//
// SwiftUI Settings row displaying the live GitHub REST API call counter.
import RunBotCore
import SwiftUI

// MARK: - CounterPollingModifier

private struct CounterPollingModifier: ViewModifier {
    let vm: APICallCounterViewModel
    func body(content: Content) -> some View {
        content
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
    }
}

extension View {
    public func counterPolling(_ vm: APICallCounterViewModel) -> some View {
        modifier(CounterPollingModifier(vm: vm))
    }
}

// MARK: - APICallCounterRow

/// Settings row showing the GitHub REST API call count + progress bar.
///
/// Layout (matches every other row in SettingsView+Sections.swift):
///
///   HStack(alignment: .center)
///   ├── VStack(leading): title
///   │                    description  ← multiline, grows down, never bleeds right
///   ├── Spacer()
///   └── HStack: count + progressbar  ← layoutPriority(1), horizontally side-by-side,
///                                       vertically centered by parent HStack
public struct APICallCounterRow: View {
    @State private var vm = APICallCounterViewModel()
    private let resetDate: Date?

    public init(resetDate: Date? = nil) {
        self.resetDate = resetDate
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {

            // Leading — title + description, left-aligned, grows downward
            VStack(alignment: .leading, spacing: 2) {
                Text("API Calls (last hour)")
                    .font(.system(size: 12))
                Text("Tracks GitHub API requests consumed in the current rate-limit window.")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
            }

            Spacer()

            // Trailing — count + progress bar, horizontal, vertically centered by parent
            HStack(alignment: .center, spacing: 6) {
                Text(vm.label)
                    .font(.system(size: 12))
                    .foregroundStyle(vm.statusColor)
                    .monospacedDigit()
                ProgressView(value: vm.snap.fraction)
                    .frame(width: 60)
                    .tint(vm.statusColor)
            }
            .layoutPriority(1)
        }
        .help(
            """
            GitHub REST calls in the last 60 minutes.
            Limit resets on a rolling basis.
            Paginated fetches count as 1 call regardless of page count.
            Only successful (non-nil) calls are counted.
            """
        )
        .onChange(of: resetDate) { _, newVal in vm.resetDate = newVal }
        .onAppear { vm.resetDate = resetDate }
        .counterPolling(vm)
    }
}
