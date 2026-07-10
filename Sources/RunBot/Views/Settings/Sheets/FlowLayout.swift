// FlowLayout.swift
// RunBot
import SwiftUI

// MARK: - FlowLayout

/// A custom `Layout` that wraps child views into rows like a word-wrapped line of text.
/// Used to arrange variable-insertion pill buttons beneath a command editor.
struct FlowLayout: Layout {
    /// Horizontal and vertical gap between child views.
    var spacing: CGFloat = 6

    /// Returns the minimum size needed to fit all subviews within `proposal.width`.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowH)
    }

    /// Places each subview left-to-right, wrapping to a new row when the width is exceeded.
    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
    }
}
