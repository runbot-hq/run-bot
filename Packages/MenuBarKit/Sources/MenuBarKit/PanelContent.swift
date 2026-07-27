// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the sizing pipeline.
//
// HOW SIZING WORKS — read this before touching anything here:
//
// 1. `MBKHostingView` is configured with `sizingOptions = [.intrinsicContentSize]`,
//    so AppKit asks SwiftUI for the root's size under an *unspecified* proposal.
// 2. The root is `MBKPanelContentView`, which is just the adopter's content
//    wrapped in `.frame(minWidth:maxWidth:maxHeight:)`. Under an unspecified
//    proposal a flexible frame returns the child's ideal size clamped into that
//    range — that clamped value becomes `intrinsicContentSize`.
// 3. `MBKPanelController` turns that size into a window frame and applies it.
//    The hosting view now has a concrete bounds, so SwiftUI re-proposes exactly
//    that size to the content. A `ScrollView` inside therefore receives the
//    capped height and scrolls instead of overflowing.
// 4. The second pass measures the same value, so the loop converges after one
//    round trip. The coalescer's 1pt dedupe absorbs float noise.
//
// ❌ NEVER add `.fixedSize()` in this wrapper. It would make the content ignore
//    the concrete proposal in step 3, and every capped scroll view would
//    overflow the panel instead of scrolling — that is exactly the class of bug
//    #2278/#2279 were about.
// ❌ NEVER measure with a `GeometryReader`. A geometry reader sees the size we
//    already applied, not the size the content wants, so it cannot detect growth.
import AppKit
import Observation
import SwiftUI

// MARK: - Limits

/// Live sizing limits handed to the SwiftUI content.
///
/// Observable so that a change to `maxContentHeight` (recomputed on every open
/// and on screen-parameter changes) re-lays-out the content without rebuilding
/// the hosting view.
@Observable
@MainActor
final class MBKPanelLimits {

    /// Minimum content width in points.
    var minWidth: CGFloat

    /// Maximum content width in points.
    var maxWidth: CGFloat

    /// Maximum content height in points, recomputed live from the current screen.
    var maxContentHeight: CGFloat

    /// Creates a limits object.
    /// - Parameters:
    ///   - minWidth: Minimum content width in points.
    ///   - maxWidth: Maximum content width in points.
    ///   - maxContentHeight: Maximum content height in points.
    init(minWidth: CGFloat, maxWidth: CGFloat, maxContentHeight: CGFloat) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxContentHeight = maxContentHeight
    }
}

// MARK: - Root view

/// Root SwiftUI view of the panel: the adopter's content plus the size limits.
struct MBKPanelContentView: View {

    /// Live sizing limits.
    let limits: MBKPanelLimits

    /// The adopter's content.
    let content: AnyView

    /// Applies the width range and the live height cap.
    var body: some View {
        content
            .frame(
                minWidth: limits.minWidth,
                maxWidth: limits.maxWidth,
                maxHeight: limits.maxContentHeight
            )
    }
}

// MARK: - Hosting view

/// `NSHostingView` that tells the controller when SwiftUI wants a different size.
///
/// AppKit calls `invalidateIntrinsicContentSize()` whenever the hosted content's
/// intrinsic size becomes stale. That is the only signal in the pipeline; the
/// controller coalesces it and reads `intrinsicContentSize` on the next turn.
final class MBKHostingView: NSHostingView<MBKPanelContentView> {

    /// Called on the main actor when the intrinsic content size may have changed.
    var onIntrinsicSizeChange: (@MainActor () -> Void)?

    /// Creates the hosting view.
    /// - Parameter rootView: The panel root view.
    required init(rootView: MBKPanelContentView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = true
    }

    /// Not supported — the panel is built in code.
    /// - Parameter coder: Unused.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Forwards AppKit's invalidation to the controller.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}
