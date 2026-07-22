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

/// Settings row that shows "410 / 5,000" with a colour-coded progress bar
/// and a static description sub-label. Layout:
///
///   HStack
///   ├── VStack(leading): title (shrinks) + description (multiline, grows down)
///   └── VStack: Spacer / HStack(number + bar) / Spacer  ← vertically centred
///
/// The trailing VStack stretches to full row height via .frame(maxHeight: .infinity)
/// so the Spacers have real height to divide, centering the number+bar HStack.
/// layoutPriority(1) on the trailing side means it always wins space negotiation;
/// the leading VStack yields and its title shrinks before the trailing is touched.
///
/// Usage:
/// ```swift
/// APICallCounterRow(resetDate: runnerState.rateLimitResetDate)
/// ```
public struct APICallCounterRow: View {
    /// View model that drives the counter label, colour, and snapshot.
    @State private var vm = APICallCounterViewModel()

    /// Optional rate-limit reset date forwarded from `RunnerState.rateLimitResetDate`.
    private let resetDate: Date?

    public init(resetDate: Date? = nil) {
        self.resetDate = resetDate
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {

            // Leading: title shrinks before trailing is touched;
            // description is multiline and grows the row downward.
            VStack(alignment: .leading, spacing: 2) {
                Text("API Calls (last hour)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Tracks GitHub API requests consumed in the current rate-limit window.")
                    .font(.caption2)
                    .foregroundStyle(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // layoutPriority(0) — yields space to trailing when width is tight

            // Trailing: number + progress bar, horizontally side-by-side,
            // vertically centred against the full row height.
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(vm.label)
                        .font(.system(size: 12))
                        .foregroundStyle(vm.statusColor)
                        .monospacedDigit()
                        .fixedSize()
                    ProgressView(value: vm.snap.fraction)
                        .frame(width: 60)
                        .tint(vm.statusColor)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
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
