// APICallCounterRow.swift
// RunBot
//
// SwiftUI Settings row displaying the live GitHub REST API call counter.
import RunBotCore
import SwiftUI

// MARK: - CounterPollingModifier

/// Starts the counter's polling loop when the modified view appears and
/// stops it when the view disappears, so the background Task only runs
/// while the Settings panel is on screen.
private struct CounterPollingModifier: ViewModifier {
    /// The view model whose polling lifecycle this modifier manages.
    let vm: APICallCounterViewModel
    /// Wraps `content` with `onAppear`/`onDisappear` hooks that start and stop polling.
    func body(content: Content) -> some View {
        content
            .onAppear { vm.startPolling() }
            .onDisappear { vm.stopPolling() }
    }
}

/// Extends `View` with a convenience modifier for wiring `APICallCounterViewModel` polling.
extension View {
    /// Binds the `APICallCounterViewModel` polling lifecycle to this view's
    /// appearance. Polling starts on `onAppear` and stops on `onDisappear`.
    ///
    /// Marked `public` so that app-layer views outside `RunBot` can wire
    /// the lifecycle when `APICallCounterRow` is embedded in a custom parent.
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
    /// View model that drives the counter label, colour, and snapshot.
    /// `@State` so SwiftUI owns the lifetime and the instance survives view identity changes.
    @State private var vm = APICallCounterViewModel()
    /// Optional rate-limit reset date forwarded from `RunnerState.rateLimitResetDate`.
    /// `nil` when no rate-limit response has been received yet; the reset sub-label is
    /// suppressed when this is `nil`.
    private let resetDate: Date?

    /// Creates a new `APICallCounterRow` with a fresh view model.
    /// - Parameter resetDate: Optional rate-limit reset date from `RunnerState`.
    public init(resetDate: Date? = nil) {
        self.resetDate = resetDate
    }

    /// The row body: leading title/description block (left-aligned, shrinks first) and
    /// trailing count/progress block (right-aligned, always natural width, vertically centered).
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
        // SYNC INVARIANT — both modifiers are required, do not remove either:
        // • onAppear  → seeds the VM on first render AND re-syncs after the view
        //               returns from off-screen (Settings closed and reopened).
        // • onChange  → keeps the VM live while the view stays on screen.
        // Removing onAppear breaks re-entry; removing onChange breaks live updates.
        .onChange(of: resetDate) { _, newVal in vm.resetDate = newVal }
        .onAppear { vm.resetDate = resetDate }
        .counterPolling(vm)
    }
}
